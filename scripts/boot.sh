#!/bin/bash
# =============================================================================
#  scripts/boot.sh — one-command cluster boot
# =============================================================================
#  Runs the full morning sequence end-to-end:
#    1. terraform apply -auto-approve  (EKS + addons + OTel + Prom + ECR)
#    2. aws eks update-kubeconfig       (point local kubectl at the new cluster)
#    3. kubectl apply -f GitOps/root-app.yaml  (bootstrap ArgoCD app-of-apps)
#    4. wait for all ArgoCD Applications to reach Synced + Healthy
#    5. wait for the ecom Ingress to get its NLB DNS populated
#    6. print every URL you need in the browser, in one tidy block
#
#  Jenkins is DELIBERATELY not part of this. Start it manually only on days
#  you push code (see printed command at the end).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="$REPO_DIR/terraform"
ROOT_APP="$REPO_DIR/GitOps/root-app.yaml"

REGION="us-east-2"
CLUSTER_NAME="ecom"
JENKINS_INSTANCE_ID="i-064da78bb3513dfb2"
JENKINS_ELASTIC_IP="13.58.87.221"

# Pretty-print helpers
BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
step()  { echo ""; echo "${BOLD}${CYAN}==> $*${RESET}"; }
ok()    { echo "${GREEN}  OK: $*${RESET}"; }
warn()  { echo "${YELLOW}  WARN: $*${RESET}"; }

START_TS=$(date +%s)

# ─────────────────────────────────────────────────────────────────────────────
#  1a. terraform apply — PHASE 1: cluster + nodes only (via -target)
# ─────────────────────────────────────────────────────────────────────────────
#  Why two phases?
#    otel-instrumentation.tf uses `kubernetes_manifest` to apply an
#    Instrumentation CR. That provider reads live CRDs from the K8s API at
#    PLAN time (not just apply time). On a fresh cluster there is no API
#    yet AND no kubeconfig → plan dies with "no client config".
#
#    Fix (industry-standard first-run bootstrap pattern):
#      Phase 1: -target the EKS cluster + node group. Terraform builds the
#               VPC + IAM + cluster + nodes and STOPS — never touches any
#               kubernetes_* / helm_* resource, so no K8s API call happens.
#      Between: aws eks update-kubeconfig → now kubectl can reach the API.
#      Phase 2: plain `terraform apply` finishes the rest. kubernetes_manifest
#               plans successfully because the API is live.
#
#    HashiCorp docs call `-target` a "last resort" because it can mask
#    dependency bugs. For first-run bootstrap it is the accepted exception.
# ─────────────────────────────────────────────────────────────────────────────
step "Step 1/7: terraform apply PHASE 1 — cluster + nodes (-target, ~10 min)"
cd "$TERRAFORM_DIR"
terraform apply -auto-approve \
  -target=aws_eks_cluster.this \
  -target=aws_eks_node_group.this
ok "EKS cluster + node group ready"

# ─────────────────────────────────────────────────────────────────────────────
#  1b. kubeconfig refresh — must run BEFORE phase 2 or kubernetes_manifest
#       plans against an empty client config and fails again.
# ─────────────────────────────────────────────────────────────────────────────
step "Step 2/7: aws eks update-kubeconfig"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
ok "kubeconfig points at $CLUSTER_NAME"

# Quick sanity ping — no point continuing if API isn't reachable
if ! kubectl get nodes >/dev/null 2>&1; then
  warn "kubectl can't reach the cluster API yet. Sleeping 15s and retrying..."
  sleep 15
  kubectl get nodes
fi
ok "cluster API reachable"

# ─────────────────────────────────────────────────────────────────────────────
#  1c. terraform apply — PHASE 2: OTel operator (install its CRDs)
# ─────────────────────────────────────────────────────────────────────────────
#  Why ANOTHER -target pass?
#    otel-instrumentation.tf has a `kubernetes_manifest` of kind:
#    Instrumentation, which is a CRD installed by the OTel operator Helm
#    chart. Like `kubernetes_manifest` with no client config, the provider
#    also validates CRD KINDS at PLAN time — "does the API know what
#    kind=Instrumentation in group=opentelemetry.io means?" If the chart
#    hasn't run yet, the answer is no → plan dies with:
#        "no matches for kind Instrumentation in group opentelemetry.io"
#
#    depends_on does NOT help — it orders APPLY, not PLAN. Plan validates
#    every resource first before any apply happens.
#
#    Fix: install the OTel operator (and its CRDs) in its own targeted
#    apply BEFORE the full apply plans against the Instrumentation CR.
#
#    Only this one -target is needed — grep confirmed there is exactly
#    one `kubernetes_manifest` in our Terraform. Any new one that depends
#    on a Helm-installed CRD needs to be added here too.
# ─────────────────────────────────────────────────────────────────────────────
step "Step 3/7: terraform apply PHASE 2 — OTel operator CRDs (-target, ~90 sec)"
terraform apply -auto-approve -target=helm_release.otel_operator
ok "OTel operator + CRDs installed"

# Quick sanity: the CRD must now be registered or phase 3 will crash again.
if ! kubectl get crd instrumentations.opentelemetry.io >/dev/null 2>&1; then
  warn "Instrumentation CRD not registered yet. Sleeping 10s and retrying..."
  sleep 10
  kubectl get crd instrumentations.opentelemetry.io
fi
ok "Instrumentation CRD registered"

# ─────────────────────────────────────────────────────────────────────────────
#  1d. terraform apply — PHASE 3: everything else
# ─────────────────────────────────────────────────────────────────────────────
#  The K8s API is live AND the Instrumentation CRD exists, so
#  kubernetes_manifest / remaining helm_release resources all plan + apply
#  cleanly. This pass installs:
#    addons (coredns, ebs-csi, vpc-cni), nginx-ingress, aws-lb-controller,
#    metrics-server, cluster-autoscaler, argocd, kube-prom-stack,
#    otel-collector (agent + gateway), Sloth, the Instrumentation CR, ECR,
#    SQS, Secrets Manager, IRSA roles, etc.
# ─────────────────────────────────────────────────────────────────────────────
step "Step 4/7: terraform apply PHASE 3 — addons, Helm, CRs (~4 min)"
terraform apply -auto-approve
ok "terraform apply complete"

# ─────────────────────────────────────────────────────────────────────────────
#  3. bootstrap ArgoCD root-app
# ─────────────────────────────────────────────────────────────────────────────
step "Step 5/7: kubectl apply root-app.yaml (bootstraps ArgoCD app-of-apps)"

# ArgoCD namespace is created by Terraform (helm_release.argocd). Wait for its
# API server before applying the Application (otherwise the apply races and
# fails with 'no matches for kind Application').
echo "  Waiting for ArgoCD CRDs to be registered..."
for i in {1..60}; do
  if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    ok "ArgoCD CRDs ready"
    break
  fi
  sleep 5
done

kubectl apply -f "$ROOT_APP"
ok "root-app applied"

# ─────────────────────────────────────────────────────────────────────────────
#  4. wait for ALL ArgoCD Applications to be Synced + Healthy
# ─────────────────────────────────────────────────────────────────────────────
step "Step 6/7: wait for every ArgoCD Application to be Synced + Healthy"
echo "  This is where the real work happens — ecom-dev syncs all services,"
echo "  grafana-dashboards drops in our golden-signals dashboard, etc."
echo ""

# Poll up to ~8 min. Fine-grained logging so you see progress.
DEADLINE=$(( $(date +%s) + 480 ))
while true; do
  # Grab name, sync, health in three columns. Strip header.
  STATUS=$(kubectl get applications -n argocd \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
    --no-headers 2>/dev/null || echo "")

  if [ -z "$STATUS" ]; then
    echo "  No Applications visible yet..."
  else
    echo "$STATUS" | awk '{printf "    %-30s %-12s %-12s\n", $1, $2, $3}'

    # Pass only when EVERY row is Synced AND Healthy
    BAD=$(echo "$STATUS" | awk '$2 != "Synced" || $3 != "Healthy" {print $1}')
    if [ -z "$BAD" ]; then
      ok "all Applications Synced + Healthy"
      break
    fi
  fi

  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    warn "Timeout waiting for ArgoCD sync. Current state above — inspect manually with:"
    warn "    kubectl get applications -n argocd"
    break
  fi
  sleep 10
done

# ─────────────────────────────────────────────────────────────────────────────
#  5. wait for the ecom Ingress NLB DNS
# ─────────────────────────────────────────────────────────────────────────────
step "Step 7/7: wait for Ingress NLB DNS to populate (~2 min)"
INGRESS_DNS=""
DEADLINE=$(( $(date +%s) + 300 ))
while [ -z "$INGRESS_DNS" ]; do
  INGRESS_DNS=$(kubectl get ingress ecom-ingress -n ecom \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$INGRESS_DNS" ]; then
    ok "ingress live: $INGRESS_DNS"
    break
  fi
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    warn "Timeout waiting for Ingress. Check: kubectl get ingress -A"
    INGRESS_DNS="(not ready yet — rerun 'kubectl get ingress -n ecom' in a minute)"
    break
  fi
  echo "  still waiting for Ingress NLB..."
  sleep 10
done

# ─────────────────────────────────────────────────────────────────────────────
#  Final report — one tidy URL block
# ─────────────────────────────────────────────────────────────────────────────
TOTAL=$(( $(date +%s) - START_TS ))
MINS=$(( TOTAL / 60 )); SECS=$(( TOTAL % 60 ))

cat <<EOF

${BOLD}${GREEN}============================================================${RESET}
${BOLD}${GREEN} Cluster ready. Total boot time: ${MINS}m ${SECS}s${RESET}
${BOLD}${GREEN}============================================================${RESET}

${BOLD}${CYAN}Open in browser directly (no port-forward needed):${RESET}

  Frontend:   ${BOLD}http://${INGRESS_DNS}${RESET}
  Jenkins:    ${BOLD}http://${JENKINS_ELASTIC_IP}:8080${RESET}
              (start first if stopped: aws ec2 start-instances --instance-ids ${JENKINS_INSTANCE_ID} --region ${REGION})

${BOLD}${CYAN}Local access via port-forward — run each in its own terminal:${RESET}

  ${BOLD}Grafana${RESET}     (admin / prom-operator)
    kubectl port-forward -n observability svc/kube-prom-stack-grafana 3000:80
    → http://localhost:3000

  ${BOLD}Prometheus${RESET}
    kubectl port-forward -n observability svc/kube-prom-stack-kube-prome-prometheus 9090:9090
    → http://localhost:9090

  ${BOLD}ArgoCD${RESET}      (admin / password from: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
    kubectl port-forward -n argocd svc/argocd-server 8081:443
    → https://localhost:8081

${BOLD}${CYAN}Golden Signals dashboard:${RESET}
  Grafana → Dashboards → Ecom folder → "Golden Signals — Ecom Services"
  Pick a service from the top-left dropdown.

${BOLD}${CYAN}Generate steady load to light up RED panels:${RESET}
  while true; do curl -s -o /dev/null http://${INGRESS_DNS}/; sleep 0.5; done

EOF
