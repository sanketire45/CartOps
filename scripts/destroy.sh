#!/bin/bash
# =============================================================================
#  scripts/destroy.sh — safe daily cluster teardown
# =============================================================================
#  Why this isn't just `terraform destroy`:
#    1. StatefulSet PVCs are NOT in Terraform state — their EBS volumes
#       survive terraform destroy and keep costing money.
#    2. ArgoCD Applications carry a finalizer that only ArgoCD itself can
#       remove. If terraform kills ArgoCD before the apps are deleted, the
#       Application + its child Namespaces hang in Terminating forever →
#       terraform destroy times out ('context deadline exceeded').
#    3. Services of type LoadBalancer provision an AWS ELB. Deleting the
#       Service is what detaches the ELB; if the aws-load-balancer-controller
#       is gone first, the Service hangs and the namespace can't terminate.
#    4. Helm's uninstall hooks need a live K8s API — they time out when the
#       cluster is going down. Faster to drop them from state.
#    5. Jenkins EC2 master is NOT in Terraform state (provisioned once,
#       Elastic IP attached). Stop it (don't terminate) so EBS/config/IP
#       survive for tomorrow.
#    6. Kyverno admission webhooks intercept DELETE requests. If Kyverno pods
#       die before resources are deleted, DELETEs time out → namespaces hang.
#    7. ECK puts finalizer.elasticsearch.k8s.elastic.co on Elasticsearch CRs.
#       Once the ECK operator is gone the finalizer can never be removed.
#    8. KEDA puts finalizer.keda.sh on ScaledObject/TriggerAuthentication.
#       Same problem — must delete before the operator is gone.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="$(cd "$SCRIPT_DIR/../terraform" && pwd)"

REGION="us-east-2"
JENKINS_INSTANCE_ID="i-064da78bb3513dfb2"

BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
step() { echo ""; echo "${BOLD}${CYAN}==> $*${RESET}"; }
ok()   { echo "${GREEN}  OK: $*${RESET}"; }
warn() { echo "${YELLOW}  WARN: $*${RESET}"; }

# ─────────────────────────────────────────────────────────────────────────────
#  0. Kyverno webhooks — disable FIRST so they can't block any later deletes
# ─────────────────────────────────────────────────────────────────────────────
# Kyverno's validating + mutating webhooks intercept every DELETE. If Kyverno
# pods die mid-cleanup the webhook call times out → DELETE returns an error →
# resources can't be removed → namespaces hang Terminating. Deleting the
# webhook configurations tells the API server to stop calling Kyverno.
step "Pre-destroy 0/6: remove Kyverno admission webhooks"
kubectl delete mutatingwebhookconfiguration \
  kyverno-policy-mutating-webhook-cfg \
  kyverno-resource-mutating-webhook-cfg \
  kyverno-verify-mutating-webhook-cfg \
  --ignore-not-found 2>/dev/null || true
kubectl delete validatingwebhookconfiguration \
  kyverno-cleanup-validating-webhook-cfg \
  kyverno-exception-validating-webhook-cfg \
  kyverno-global-context-validating-webhook-cfg \
  kyverno-policy-validating-webhook-cfg \
  kyverno-resource-validating-webhook-cfg \
  kyverno-ttl-validating-webhook-cfg \
  keda-admission \
  --ignore-not-found 2>/dev/null || true
ok "Kyverno + KEDA admission webhooks removed"

# ─────────────────────────────────────────────────────────────────────────────
#  1. ECK Elasticsearch CR — delete BEFORE ECK operator is gone
# ─────────────────────────────────────────────────────────────────────────────
# ECK puts finalizer.elasticsearch.k8s.elastic.co on its Elasticsearch CR.
# Once the ECK operator (elastic-system) pod is gone, the finalizer can never
# be cleared and elastic-system hangs Terminating forever.
step "Pre-destroy 1/6: delete ECK Elasticsearch + Kibana CRs"
if kubectl get crd elasticsearches.elasticsearch.k8s.elastic.co &>/dev/null 2>&1; then
  kubectl delete elasticsearch --all --all-namespaces --timeout=90s 2>/dev/null || warn "Elasticsearch delete incomplete"
  kubectl delete kibana --all --all-namespaces --timeout=30s 2>/dev/null || true
  ok "ECK resources deleted"
else
  echo "  ECK CRD not present — skipping."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  2. KEDA custom resources — delete BEFORE KEDA operator is gone
# ─────────────────────────────────────────────────────────────────────────────
# ScaledObject and TriggerAuthentication carry finalizer.keda.sh.
# kubectl delete all skips custom resources, so if KEDA operator is killed
# first the finalizer can never be cleared → namespace hangs Terminating.
step "Pre-destroy 2/6: delete KEDA ScaledObjects + TriggerAuthentications"
if kubectl get crd scaledobjects.keda.sh &>/dev/null 2>&1; then
  kubectl delete scaledobject --all --all-namespaces --timeout=30s 2>/dev/null || true
  kubectl delete triggerauthentication --all --all-namespaces --timeout=30s 2>/dev/null || true
  ok "KEDA custom resources cleared"
else
  echo "  KEDA CRD not present — skipping."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  3. StatefulSet PVCs — delete pods first, then PVCs to free EBS volumes
# ─────────────────────────────────────────────────────────────────────────────
# PVCs are NOT in Terraform state — the EBS volumes survive terraform destroy
# and keep accruing cost. Delete StatefulSet pods first so the PVCs detach,
# then delete the PVCs themselves.
step "Pre-destroy 3/6: delete all StatefulSet PVCs (frees EBS)"
# Kill StatefulSet pods so their PVCs detach
for NS in ecom observability elastic-system; do
  if kubectl get ns "$NS" &>/dev/null 2>&1; then
    kubectl delete statefulset --all -n "$NS" --wait=false 2>/dev/null || true
    kubectl delete pods --all -n "$NS" --wait=false 2>/dev/null || true
  fi
done
# Short wait for pod termination so PVCs are detached
sleep 5
# Now delete all PVCs across all namespaces
kubectl delete pvc --all --all-namespaces --wait=false 2>/dev/null || warn "some PVCs didn't delete cleanly"
ok "All PVCs queued for deletion (EBS volumes releasing)"

# ─────────────────────────────────────────────────────────────────────────────
#  4. ArgoCD Applications — strip finalizers + delete BEFORE ArgoCD goes away
# ─────────────────────────────────────────────────────────────────────────────
step "Pre-destroy 4/6: delete ArgoCD Applications (prevents namespace hang)"
if kubectl get crd applications.argoproj.io &>/dev/null 2>&1; then
  APPS=$(kubectl get applications -n argocd -o name 2>/dev/null || true)
  if [ -n "$APPS" ]; then
    echo "  Found ArgoCD Applications — stripping finalizers first:"
    echo "$APPS" | while read -r app; do
      echo "    patching $app"
      kubectl patch "$app" -n argocd --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done
    echo "  Deleting Applications..."
    kubectl delete applications --all -n argocd --timeout=60s 2>/dev/null || warn "some apps didn't delete cleanly"
    ok "ArgoCD Applications cleared"
  else
    echo "  No ArgoCD Applications to delete."
  fi
else
  echo "  ArgoCD CRD not present — skipping."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  5. Services / Ingress — detach AWS LBs WHILE the controllers are alive
# ─────────────────────────────────────────────────────────────────────────────
step "Pre-destroy 5/6: delete Ingresses + LoadBalancer Services (detaches AWS ELBs)"
echo "  Deleting all Ingress resources..."
kubectl delete ingress --all --all-namespaces --timeout=60s 2>/dev/null || warn "some ingresses didn't delete cleanly"

echo "  Deleting all LoadBalancer-type Services..."
kubectl get svc --all-namespaces -o json 2>/dev/null \
  | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "-n \(.metadata.namespace) \(.metadata.name)"' 2>/dev/null \
  | while read -r args; do
      [ -n "$args" ] && kubectl delete svc $args --timeout=60s 2>/dev/null || true
    done
ok "AWS LBs detaching"

# Grace period so AWS finishes releasing ELBs before the LB controller dies.
sleep 15

# ─────────────────────────────────────────────────────────────────────────────
#  6. Helm releases — drop from Terraform state (avoids uninstall hook timeouts)
# ─────────────────────────────────────────────────────────────────────────────
step "Pre-destroy 6a/6: remove Helm releases from Terraform state"
cd "$TERRAFORM_DIR"
HELM_RESOURCES=$(terraform state list 2>/dev/null | grep '^helm_release\.' || true)
if [ -n "$HELM_RESOURCES" ]; then
  echo "$HELM_RESOURCES" | while read -r res; do
    echo "    removing $res"
    terraform state rm "$res" 2>/dev/null || true
  done
  ok "Helm releases dropped from state"
else
  echo "  No Helm releases in state."
fi

# Also drop the OTel Instrumentation CR from state — terraform will try to
# delete it via the K8s API after the OTel operator is gone, which races.
# Dropping it means the CR is simply abandoned (cleaned up with the cluster).
step "Pre-destroy 6b/6: drop OTel Instrumentation CR from Terraform state"
terraform state rm kubernetes_manifest.ecom_java_instrumentation 2>/dev/null || true
ok "OTel Instrumentation CR removed from state"

# ─────────────────────────────────────────────────────────────────────────────
#  6c. Namespace finalizers — nuclear safety net for anything still stuck
# ─────────────────────────────────────────────────────────────────────────────
step "Pre-destroy 6c/6: strip namespace finalizers + flush remaining resources"
ALL_NS="ecom observability argocd elastic-system external-secrets ingress-nginx kyverno opentelemetry-operator-system sloth"
for NS in $ALL_NS; do
  if kubectl get ns "$NS" &>/dev/null 2>&1; then
    kubectl delete all --all -n "$NS" --timeout=30s --wait=false 2>/dev/null || true
    PHASE=$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$PHASE" = "Terminating" ]; then
      warn "namespace $NS is stuck Terminating — stripping finalizer"
      kubectl get ns "$NS" -o json 2>/dev/null \
        | jq '.spec.finalizers=[]' \
        | kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - 2>/dev/null || true
    fi
  fi
done
ok "namespace finalizers checked"

# ─────────────────────────────────────────────────────────────────────────────
#  7. terraform destroy
# ─────────────────────────────────────────────────────────────────────────────
step "Running terraform destroy"
terraform destroy -auto-approve

# ─────────────────────────────────────────────────────────────────────────────
#  8. Stop Jenkins EC2 (keeps EBS + Elastic IP alive at near-zero cost)
# ─────────────────────────────────────────────────────────────────────────────
step "Post-destroy: stop Jenkins EC2 master"
STATE=$(aws ec2 describe-instances \
  --instance-ids "$JENKINS_INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null || echo "unknown")

echo "  Jenkins instance $JENKINS_INSTANCE_ID state: $STATE"
case "$STATE" in
  running)
    echo "  Stopping..."
    aws ec2 stop-instances --instance-ids "$JENKINS_INSTANCE_ID" --region "$REGION" >/dev/null
    ok "Jenkins stop issued (EBS + Elastic IP preserved)"
    ;;
  stopped|stopping)
    ok "Jenkins already stopped/stopping — nothing to do"
    ;;
  unknown)
    warn "could not query Jenkins state (AWS CLI error) — check manually"
    ;;
  *)
    warn "Jenkins in unexpected state '$STATE' — leaving it alone"
    ;;
esac

echo ""
echo "${BOLD}${GREEN}=== Teardown complete. ===${RESET}"
