#!/bin/bash
# =============================================================================
#  scripts/ecr-lifecycle.sh — manage ECR repos + lifecycle policy out-of-band
# =============================================================================
#  ECR repos (and their images) live OUTSIDE Terraform. This script is the
#  authoritative owner.
#
#  WHY — the design intent:
#    1. We want ECR to SURVIVE `terraform destroy` so the baseline v0.0.0
#       image stays around. A fresh `boot.sh` can then pull v0.0.0 without
#       needing to start Jenkins.
#    2. Jenkins only runs when there is a code change. Each run pushes a
#       new image tag. Intraday, several images can accumulate (useful
#       for Argo rollback within the day).
#    3. The lifecycle policy keeps the N most-recent images per repo —
#       currently 2 (current + 1 rollback step) — minimum rollback window,
#       and the baseline sits unmolested when nothing newer is pushed.
#
#  WHAT IT DOES:
#    For each ECR repo:
#      - If the repo doesn't exist, CREATE it (IMMUTABLE tags, scan-on-push).
#      - PUT the lifecycle policy (keep 2 newest images).
#    Idempotent — re-running just confirms the same state.
#
#  WHEN TO RUN:
#    - First-time project setup (creates the repos)
#    - After editing the policy below
#    - Normally never — this is a one-shot per environment
#
#  COST NOTE:
#    Each image layer ≈ 300 MB compressed. 2 images × 5 repos × 300 MB
#    ≈ 3 GB in ECR ≈ $0.30/month. Peanuts. This is for tidiness and
#    one-step rollback headroom, not savings.
# =============================================================================

set -euo pipefail

REGION="us-east-2"

# Authoritative repo list for this project. Keep in sync with k8s/*/deployment
# manifests' image references.
REPOS=(
  "ecom-product-category"
  "ecom-order-service"
  "ecom-eureka-server"
  "ecom-notification-worker"
  "ecom-frontend"
)

# Lifecycle policy — keep the 2 most recent images per repo.
# WHY 2:
#   - 1 = current (what the YAML references)
#   - 1 extra slot = one-step rollback (Argo rollback → previous image)
#   - If no new pushes happen, count stays at 1 (never exceeds 2), so the
#     baseline is never expired. "nothing happens, nothing changes."
#   - After a pipeline push, the oldest beyond the newest 2 gets expired.
#     Example: repo has v0.0.0 → push v0.0.1 → both kept (count=2).
#              Push v0.0.2 → v0.0.0 expires, v0.0.1 + v0.0.2 kept.
#   - ECR evaluates lifecycle rules on push AND periodically (within ~24h).
POLICY=$(cat <<'JSON'
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep only the 2 most recent images (current + 1 rollback slot)",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 2
      },
      "action": { "type": "expire" }
    }
  ]
}
JSON
)

BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
ok()   { echo "${GREEN}  OK: $*${RESET}"; }
info() { echo "${CYAN}  info: $*${RESET}"; }
warn() { echo "${YELLOW}  WARN: $*${RESET}"; }

echo "${BOLD}Ensuring ECR repos + lifecycle policy for ${#REPOS[@]} services...${RESET}"
echo "Region: $REGION"
echo ""

for repo in "${REPOS[@]}"; do
  echo "→ $repo"

  # Step 1: ensure the repo exists. Create it with IMMUTABLE tags + scan-on-push
  # if it doesn't (matches the old Terraform config).
  if aws ecr describe-repositories \
        --repository-names "$repo" \
        --region "$REGION" \
        >/dev/null 2>&1; then
    info "repo exists"
  else
    info "repo missing — creating"
    aws ecr create-repository \
      --repository-name "$repo" \
      --image-tag-mutability IMMUTABLE \
      --image-scanning-configuration scanOnPush=true \
      --tags Key=Service,Value="$repo" Key=ManagedBy,Value=ecr-lifecycle-script \
      --region "$REGION" \
      >/dev/null
    ok "repo created"
  fi

  # Step 2: put (or overwrite) the lifecycle policy.
  aws ecr put-lifecycle-policy \
    --repository-name "$repo" \
    --lifecycle-policy-text "$POLICY" \
    --region "$REGION" \
    >/dev/null
  ok "policy applied (keep 2 newest)"
done

echo ""
echo "${BOLD}${GREEN}Done — all ${#REPOS[@]} repos have the policy.${RESET}"
echo ""
echo "Verify any one with:"
echo "  aws ecr get-lifecycle-policy --repository-name ecom-product-category --region $REGION"
echo ""
echo "List images per repo:"
echo "  for r in ${REPOS[*]}; do echo \"\$r:\"; aws ecr list-images --repository-name \"\$r\" --region $REGION --query 'imageIds[*].imageTag' --output text; done"
