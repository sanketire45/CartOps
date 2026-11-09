#!/bin/bash
# =============================================================================
#  scripts/ecr-lifecycle.sh — one-shot: apply "keep 1 image" policy to all repos
# =============================================================================
#  What it does:
#    For every ECR repo in our service list, PUT a lifecycle policy that
#    expires any image beyond the single most-recent one. Idempotent —
#    re-running just re-sets the same policy.
#
#  When to run:
#    Any time after 'terraform apply' has created the repos. Only matters
#    once the repo accumulates >1 image (i.e. after Jenkins pushes a
#    second time). First push is a no-op for the policy.
#
#  Why not in Terraform:
#    Daily 'terraform destroy' would destroy the policy too. Keeping this
#    as an out-of-band script means it can survive a future state split
#    (persistent ECR in its own terraform dir) without a refactor.
#
#  Cost note:
#    Each image layer = ~300 MB compressed. Keeping 1 per repo across
#    5 repos = ~1.2 GB in ECR = ~$0.12/month. Leaving old images = $0.10
#    per GB-month per extra image. Trivial money either way — this is for
#    tidiness, not savings.
# =============================================================================

set -euo pipefail

REGION="us-east-2"

# The 5 repos Terraform's aws_ecr_repository.services[*] creates.
# Keep in sync with terraform/ecr.tf's for_each key set.
REPOS=(
  "ecom-product-category"
  "ecom-order-service"
  "ecom-eureka-server"
  "ecom-notification-worker"
  "ecom-frontend"
)

# Policy: keep only the most recent image, regardless of tag state.
POLICY=$(cat <<'JSON'
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep only the most recent image",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 1
      },
      "action": { "type": "expire" }
    }
  ]
}
JSON
)

BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
ok()   { echo "${GREEN}  OK: $*${RESET}"; }
warn() { echo "${YELLOW}  WARN: $*${RESET}"; }

echo "${BOLD}Applying 'keep latest 1 image' lifecycle policy to ECR repos...${RESET}"
echo "Region: $REGION"
echo ""

MISSING=()
for repo in "${REPOS[@]}"; do
  echo "→ $repo"
  # Short-circuit if the repo isn't there yet (terraform apply not run).
  if ! aws ecr describe-repositories \
        --repository-names "$repo" \
        --region "$REGION" \
        >/dev/null 2>&1; then
    warn "repo '$repo' does not exist — skipping"
    MISSING+=("$repo")
    continue
  fi

  aws ecr put-lifecycle-policy \
    --repository-name "$repo" \
    --lifecycle-policy-text "$POLICY" \
    --region "$REGION" \
    >/dev/null
  ok "policy applied"
done

echo ""
if [ ${#MISSING[@]} -gt 0 ]; then
  warn "skipped ${#MISSING[@]} missing repo(s): ${MISSING[*]}"
  warn "Re-run this script after 'terraform apply' recreates them."
  exit 0
fi

echo "${BOLD}${GREEN}Done — all ${#REPOS[@]} repos now have the policy.${RESET}"
echo ""
echo "Verify any one with:"
echo "  aws ecr get-lifecycle-policy --repository-name ecom-product-category --region $REGION"
