#!/bin/bash
# scripts/destroy.sh — safe daily cluster teardown
#
# Run this instead of 'terraform destroy' directly.
# Handles one thing terraform destroy can't: StatefulSet PVCs (volumeClaimTemplates)
# are NOT tracked by Terraform — the EBS volume they create stays alive after cluster
# deletion and keeps costing money. This script deletes them first.

set -euo pipefail
TERRAFORM_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

echo "=== Pre-destroy: delete StatefulSet PVCs to avoid orphaned EBS volumes ==="

if kubectl get pvc data-mysql-0 -n ecom &>/dev/null 2>&1; then
  echo "  Deleting mysql-0 pod first (PVC can't delete while a pod holds it)..."
  kubectl delete pod mysql-0 -n ecom --wait=false 2>/dev/null || true
  echo "  Deleting data-mysql-0 PVC (this also deletes the EBS volume)..."
  kubectl delete pvc data-mysql-0 -n ecom --wait=true
  echo "  PVC deleted — EBS volume will be cleaned up by AWS."
else
  echo "  data-mysql-0 PVC not found — skipping (cluster may already be down)."
fi

echo ""
echo "=== Running terraform destroy ==="
cd "$TERRAFORM_DIR"
terraform destroy -auto-approve
