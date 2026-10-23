# =============================================================================
#  iam-jenkins.tf  —  IAM role that Jenkins assumes to push to ECR
# =============================================================================
#
#  THE PROBLEM WITH "INSTANCE ROLE DOES EVERYTHING":
#    If someone compromises the Jenkins EC2 instance they inherit all the
#    permissions on the instance role forever. Bad blast radius.
#
#  THE FIX — STS ASSUME-ROLE:
#
#    Jenkins EC2 Instance
#        └── wears: CartOps-Jenkins-Instance-Role
#                      └── permission: sts:AssumeRole → CartOps-Jenkins-CI-Role ONLY
#
#    CartOps-Jenkins-CI-Role  ← assumed per-build, expires in 1hr
#        └── permissions: ECR push (GetAuthorizationToken + push operations)
#        └── trust: only CartOps-Jenkins-Instance-Role can assume it
#
#  HOW TO USE:
#    1. terraform apply (creates CartOps-Jenkins-CI-Role)
#    2. Note the output: jenkins_ci_role_arn
#    3. Attach that ARN as ECR_ROLE_ARN in the pipeline environment block
#    4. Update your Jenkins EC2 instance role:
#         - REMOVE: direct ECR permissions
#         - ADD:    sts:AssumeRole on CartOps-Jenkins-CI-Role
#
# =============================================================================

data "aws_caller_identity" "current" {}

# ── The role Jenkins assumes per-build ────────────────────────────────────────

resource "aws_iam_role" "jenkins_ci" {
  name        = "CartOps-Jenkins-CI-Role"
  description = "Assumed by Jenkins per build to push images to ECR"

  # Trust policy: only the Jenkins instance role (by ARN) may assume this
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = {
        AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.jenkins_instance_role_name}"
      }
    }]
  })
}

# ── ECR permissions the role carries ──────────────────────────────────────────

resource "aws_iam_policy" "jenkins_ecr_push" {
  name        = "CartOps-Jenkins-ECR-Push"
  description = "Allows pushing images to CartOps ECR repos"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"    # GetAuthorizationToken has no resource scope — always *
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeImages"  # needed by dev-deploy.groovy verify stage
        ]
        Resource = [
          "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/ecom-product-category",
          "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/ecom-order-service",
          "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/ecom-eureka-server",
          "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/ecom-frontend"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_ecr_push" {
  role       = aws_iam_role.jenkins_ci.name
  policy_arn = aws_iam_policy.jenkins_ecr_push.arn
}

# ── What to add to your Jenkins EC2 instance role (inline policy) ─────────────
# Apply this yourself in the AWS console / CLI on your existing Jenkins role.
# We don't manage the instance role here because it was created outside Terraform.
#
#  {
#    "Version": "2012-10-17",
#    "Statement": [{
#      "Effect": "Allow",
#      "Action": "sts:AssumeRole",
#      "Resource": "arn:aws:iam::ACCOUNT:role/CartOps-Jenkins-CI-Role"
#    }]
#  }

output "jenkins_ci_role_arn" {
  description = "Set this as ECR_ROLE_ARN in dev-build.groovy environment block"
  value       = aws_iam_role.jenkins_ci.arn
}
