# =============================================================================
#  ecr.tf  —  4 private ECR repositories, one per service  (todo #16 + #14)
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        aws ecr create-repository --repository-name ecom-product-category \
#          --image-tag-mutability IMMUTABLE \
#          --image-scanning-configuration scanOnPush=true
#        (repeat for each service)
#
#  📖  WHAT IT DOES, SIMPLY:
#        ECR = AWS's private Docker registry. Each service gets its own repo.
#        Jenkins pushes images here tagged with the git SHA (e.g. :abc1234).
#        EKS nodes pull from here using the node role (no credentials needed).
#
#  TAG FORMAT: :<GIT_SHA>  — never :latest
#    :latest = you can't tell what's running, stale-cache bugs, rollback impossible
#    :abc1234 = unique, immutable, traceable to an exact git commit
# =============================================================================

resource "aws_ecr_repository" "services" {
  # var.ecr_repos is a map from variables.tf:
  #   { product = "ecom-product-category", order = "ecom-order-service", ... }
  # for_each creates one repo per entry.
  for_each = var.ecr_repos

  name                 = each.value
  image_tag_mutability = "IMMUTABLE" # once :abc1234 is pushed, it can NEVER be overwritten

  # todo #14: scan-on-push — every image is scanned for CVEs on arrival.
  # This is the registry-side gate. Trivy in Jenkins CI is the pre-push gate.
  # Two layers: catch early (Trivy) + enforce at registry (ECR scan).
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Service = each.key }
}


# -----------------------------------------------------------------------------
#  LIFECYCLE POLICY — automatic image cleanup (applied to every repo)
#
#  Without this: every Jenkins build leaves untagged layer artifacts.
#  ECR charges $0.10/GB/month — repos grow unboundedly without cleanup.
#
#  Rules (priority order — first match wins):
#    1. Untagged images older than 7 days → expire (build artifacts)
#    2. Tagged images beyond the last 10  → expire (old releases)
#       You'd never roll back more than 10 builds — keeping more wastes storage.
# -----------------------------------------------------------------------------
resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 10 tagged images per repo"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = [""]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}


# -----------------------------------------------------------------------------
#  OUTPUTS — Jenkins reads these to know where to push each image.
#  Full URI format: {account}.dkr.ecr.{region}.amazonaws.com/{repo-name}:{sha}
# -----------------------------------------------------------------------------
output "ecr_repo_urls" {
  description = "Full ECR repository URIs per service — Jenkins appends :<GIT_SHA>"
  value = {
    for k, repo in aws_ecr_repository.services :
    k => repo.repository_url
  }
}
