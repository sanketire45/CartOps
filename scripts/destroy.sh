#!/bin/bash
# =============================================================================
#  scripts/destroy.sh — safe daily cluster teardown
# =============================================================================
#  Why this isn't just `terraform destroy`:
#    1. StatefulSet PVCs (MySQL) are NOT in Terraform state — their EBS
#       volumes survive terraform destroy and keep costing money.
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
#  1. StatefulSet PVCs — delete first to free EBS
# ─────────────────────────────────────────────────────────────────────────────
step "Pre-destroy 1/5: delete StatefulSet PVCs (so EBS volumes release)"
if kubectl get pvc data-mysql-0 -n ecom &>/dev/null 2>&1; then
  echo "  Deleting mysql-0 pod first (PVC can't delete while a pod holds it)..."
  kubectl delete pod mysql-0 -n ecom --wait=false 2>/dev/null || true
  echo "  Deleting data-mysql-0 PVC (triggers EBS volume cleanup)..."
  kubectl delete pvc data-mysql-0 -n ecom --wait=true --timeout=60s || warn "PVC delete didn't complete cleanly"
  ok "MySQL PVC + EBS volume released"
else
  echo "  data-mysql-0 PVC not found — skipping."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  2. ArgoCD Applications — strip finalizers + delete BEFORE ArgoCD goes away
# ─────────────────────────────────────────────────────────────────────────────
step "Pre-destroy 2/5: delete ArgoCD Applications (prevents namespace hang)"
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
#  3. Services / Ingress — detach AWS LBs WHILE the controllers are alive
# ─────────────────────────────────────────────────────────────────────────────
step "Pre-destroy 3/5: delete Ingresses + LoadBalancer Services (detaches AWS NLBs)"
echo "  Deleting all Ingress resources (nginx-ingress NLB goes away)..."
kubectl delete ingress --all --all-namespaces --timeout=60s 2>/dev/null || warn "some ingresses didn't delete cleanly"

echo "  Deleting all LoadBalancer-type Services..."
# Only touch Services whose type is LoadBalancer — leave ClusterIP alone
kubectl get svc --all-namespaces -o json 2>/dev/null \
  | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "-n \(.metadata.namespace) \(.metadata.name)"' 2>/dev/null \
  | while read -r args; do
      [ -n "$args" ] && kubectl delete svc $args --timeout=60s 2>/dev/null || true
    done
ok "AWS LBs detaching"

# Short grace so AWS actually finishes releasing the NLBs/ALBs before we
# kill the controllers that could still help. 15s is usually enough.
sleep 15

# ─────────────────────────────────────────────────────────────────────────────
#  3b. KEDA custom resources — delete BEFORE KEDA operator goes away
# ─────────────────────────────────────────────────────────────────────────────
# ScaledObject and TriggerAuthentication carry finalizer.keda.sh.
# kubectl delete all --all skips custom resources, so if the KEDA operator
# is killed first the finalizer can never be cleared → namespace hangs forever.
step "Pre-destroy 3b/5: delete KEDA ScaledObjects + TriggerAuthentications"
for NS in ecom observability; do
  if kubectl get ns "$NS" &>/dev/null 2>&1; then
    kubectl delete scaledobject --all -n "$NS" --timeout=30s 2>/dev/null || true
    kubectl delete triggerauthentication --all -n "$NS" --timeout=30s 2>/dev/null || true
  fi
done
ok "KEDA custom resources cleared"

# ─────────────────────────────────────────────────────────────────────────────
#  4. Helm releases — drop from state (avoids uninstall hook timeouts)
# ─────────────────────────────────────────────────────────────────────────────
step "Pre-destroy 4/5: remove Helm releases from Terraform state"
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

# ─────────────────────────────────────────────────────────────────────────────
#  4b. Namespaces — strip finalizers so terraform doesn't hang on them
# ─────────────────────────────────────────────────────────────────────────────
step "Pre-destroy 4b/5: strip namespace finalizers (safety net)"
# After step 2/3, apps and LBs should be gone — but if anything inside the
# namespace still carries a finalizer, the ns will hang. This is the nuclear
# option: force-strip ns finalizers on the ones Terraform manages.
for NS in ecom observability argocd; do
  if kubectl get ns "$NS" &>/dev/null 2>&1; then
    # Delete any stuck resources still referencing finalizers we've already
    # addressed above (silent fail OK).
    kubectl delete all --all -n "$NS" --timeout=30s --wait=false 2>/dev/null || true
    # If the ns is already in Terminating state, strip its finalizer.
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
#  5. terraform destroy
# ─────────────────────────────────────────────────────────────────────────────
step "Running terraform destroy"
terraform destroy -auto-approve

# ─────────────────────────────────────────────────────────────────────────────
#  6. Stop Jenkins EC2 (keeps EBS + Elastic IP alive at near-zero cost)
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
