# =============================================================================
#  iam-jenkins.tf  —  Two IAM roles for Jenkins → ECR pipeline access
# =============================================================================
#
#  TWO ROLES, THAT'S IT:
#
#  Role 1: CartOps-Jenkins-Instance-Role
#    → attached to Jenkins EC2 via instance profile
#    → only permission: sts:AssumeRole on Role 2
#    → trust: EC2 service can wear it
#
#  Role 2: CartOps-Jenkins-CI-Role
#    → NOT attached to anything — pipeline assumes it per build
#    → permissions: ECR push to our 4 repos
#    → trust: only Role 1 can assume it
#    → temp creds expire after 1 hr
#
#  AFTER APPLY:
#    1. Go to EC2 console → Jenkins instance → Actions → Security
#       → Modify IAM Role → select CartOps-Jenkins-Instance-Role
#    2. ECR_ROLE_ARN in dev-build.groovy is already set to Role 2's ARN
#
# =============================================================================

data "aws_caller_identity" "current" {}

# ── Role 1: EC2 Instance Role ─────────────────────────────────────────────────

resource "aws_iam_role" "jenkins_instance" {
  name        = "CartOps-Jenkins-Instance-Role"
  description = "Worn by the Jenkins EC2 instance. Only allows assuming the CI role."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# EC2 needs an instance profile wrapper to attach a role to an instance
resource "aws_iam_instance_profile" "jenkins" {
  name = "CartOps-Jenkins-Instance-Profile"
  role = aws_iam_role.jenkins_instance.name
}

# The only thing the instance role can do: assume Role 2
resource "aws_iam_role_policy" "jenkins_instance_assume" {
  name = "AllowAssumeJenkinsCIRole"
  role = aws_iam_role.jenkins_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = aws_iam_role.jenkins_ci.arn
    }]
  })
}

# ── Role 2: Jenkins CI Role (assumed per build) ───────────────────────────────

resource "aws_iam_role" "jenkins_ci" {
  name        = "CartOps-Jenkins-CI-Role"
  description = "Assumed per build by the Jenkins pipeline. Holds ECR push permissions."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = aws_iam_role.jenkins_instance.arn }
    }]
  })
}

resource "aws_iam_policy" "jenkins_ecr_push" {
  name        = "CartOps-Jenkins-ECR-Push"
  description = "Allows pushing images to CartOps ECR repos"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"   # GetAuthorizationToken has no resource scope — always *
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
          "ecr:DescribeImages"   # needed by dev-deploy.groovy ECR verify stage
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

# ── Outputs ───────────────────────────────────────────────────────────────────

output "jenkins_instance_profile_name" {
  description = "Attach this to your Jenkins EC2: EC2 console → instance → Actions → Security → Modify IAM Role"
  value       = aws_iam_instance_profile.jenkins.name
}

output "jenkins_ci_role_arn" {
  description = "Already set as ECR_ROLE_ARN in dev-build.groovy — no action needed"
  value       = aws_iam_role.jenkins_ci.arn
}
