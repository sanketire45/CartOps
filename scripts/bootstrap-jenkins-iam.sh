#!/usr/bin/env bash
# =============================================================================
#  bootstrap-jenkins-iam.sh — run ONCE before first Jenkins pipeline run
# =============================================================================
#  WHY OUTSIDE TERRAFORM:
#    Jenkins EC2 exists outside terraform's lifecycle. If terraform destroy runs
#    (to tear down the EKS cluster), these roles must survive — Jenkins keeps
#    running. So like the S3 backend, these are created once and left alone.
#
#  WHAT THIS CREATES:
#    Role 1: CartOps-Jenkins-Instance-Role + instance profile
#              → attach to Jenkins EC2 (EC2 console → Modify IAM Role)
#              → only permission: sts:AssumeRole on Role 2
#
#    Role 2: CartOps-Jenkins-CI-Role
#              → assumed per build by the pipeline (ecr_push.groovy)
#              → permissions: ECR push to all 4 CartOps repos
#              → trust: only Role 1 can assume it
#
#  USAGE:
#    bash scripts/bootstrap-jenkins-iam.sh
#
#  IDEMPOTENT: safe to run again — skips creation if roles already exist.
#
#  AFTER RUNNING:
#    Go to EC2 console → Jenkins instance → Actions → Security
#    → Modify IAM Role → select CartOps-Jenkins-Instance-Profile
# =============================================================================

set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-east-2"

INSTANCE_ROLE="CartOps-Jenkins-Instance-Role"
INSTANCE_PROFILE="CartOps-Jenkins-Instance-Profile"
CI_ROLE="CartOps-Jenkins-CI-Role"
CI_POLICY="CartOps-Jenkins-ECR-Push"

echo "→ Account : ${ACCOUNT_ID}"
echo "→ Region  : ${REGION}"
echo ""

# ── Role 1: EC2 Instance Role ─────────────────────────────────────────────────

echo "→ Creating Role 1: ${INSTANCE_ROLE}"
aws iam create-role \
  --role-name "${INSTANCE_ROLE}" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }' \
  --description "Worn by Jenkins EC2. Only allows assuming the CI role." \
  2>/dev/null || echo "  (role already exists — skipping)"

echo "→ Creating instance profile: ${INSTANCE_PROFILE}"
aws iam create-instance-profile \
  --instance-profile-name "${INSTANCE_PROFILE}" \
  2>/dev/null || echo "  (instance profile already exists — skipping)"

aws iam add-role-to-instance-profile \
  --instance-profile-name "${INSTANCE_PROFILE}" \
  --role-name "${INSTANCE_ROLE}" \
  2>/dev/null || echo "  (role already in profile — skipping)"

# ── Role 2: Jenkins CI Role ───────────────────────────────────────────────────

INSTANCE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${INSTANCE_ROLE}"

echo "→ Creating Role 2: ${CI_ROLE}"
aws iam create-role \
  --role-name "${CI_ROLE}" \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": { \"AWS\": \"${INSTANCE_ROLE_ARN}\" },
      \"Action\": \"sts:AssumeRole\"
    }]
  }" \
  --description "Assumed per build by Jenkins pipeline. Holds ECR push permissions." \
  2>/dev/null || echo "  (role already exists — skipping)"

# ── ECR push policy ───────────────────────────────────────────────────────────

echo "→ Creating ECR push policy: ${CI_POLICY}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${CI_POLICY}"

aws iam create-policy \
  --policy-name "${CI_POLICY}" \
  --description "Allows pushing images to CartOps ECR repos" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"ECRAuth\",
        \"Effect\": \"Allow\",
        \"Action\": [\"ecr:GetAuthorizationToken\"],
        \"Resource\": \"*\"
      },
      {
        \"Sid\": \"ECRPush\",
        \"Effect\": \"Allow\",
        \"Action\": [
          \"ecr:BatchCheckLayerAvailability\",
          \"ecr:InitiateLayerUpload\",
          \"ecr:UploadLayerPart\",
          \"ecr:CompleteLayerUpload\",
          \"ecr:PutImage\",
          \"ecr:DescribeImages\"
        ],
        \"Resource\": [
          \"arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/ecom-product-category\",
          \"arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/ecom-order-service\",
          \"arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/ecom-eureka-server\",
          \"arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/ecom-frontend\"
        ]
      }
    ]
  }" \
  2>/dev/null || echo "  (policy already exists — skipping)"

echo "→ Attaching ECR policy to ${CI_ROLE}"
aws iam attach-role-policy \
  --role-name "${CI_ROLE}" \
  --policy-arn "${POLICY_ARN}" \
  2>/dev/null || echo "  (policy already attached — skipping)"

# ── Role 1 gets permission to assume Role 2 ───────────────────────────────────

CI_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CI_ROLE}"

echo "→ Adding sts:AssumeRole permission to ${INSTANCE_ROLE}"
aws iam put-role-policy \
  --role-name "${INSTANCE_ROLE}" \
  --policy-name "AllowAssumeJenkinsCIRole" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"sts:AssumeRole\",
      \"Resource\": \"${CI_ROLE_ARN}\"
    }]
  }"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "✅ Bootstrap complete."
echo ""
echo "   Role 1 (attach to EC2) : ${INSTANCE_ROLE_ARN}"
echo "   Instance profile       : ${INSTANCE_PROFILE}"
echo "   Role 2 (pipeline uses) : ${CI_ROLE_ARN}"
echo ""
echo "Next step:"
echo "  EC2 console → Jenkins instance → Actions → Security"
echo "  → Modify IAM Role → select: ${INSTANCE_PROFILE}"
