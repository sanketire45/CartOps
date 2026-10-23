#!/usr/bin/env bash
# =============================================================================
#  backend-bootstrap.sh — run ONCE before terraform init
# =============================================================================
#  WHY THIS EXISTS:
#    Terraform can't create the S3 bucket it uses as its own backend — that's
#    a chicken-and-egg problem. This script creates the bucket manually first.
#    After this runs once, all future `terraform init` / `terraform apply` runs
#    use the bucket automatically.
#
#  USAGE:
#    bash backend-bootstrap.sh
#    terraform init          (first time — initialises backend)
#    terraform init -migrate-state   (if you had a local state to move)
#
#  IDEMPOTENT: safe to run again — create-bucket returns an error if the bucket
#  already exists, which this script ignores.
# =============================================================================

set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="ecom-tfstate-${ACCOUNT_ID}"
REGION="us-east-2"

echo "→ Bootstrap account: ${ACCOUNT_ID}"
echo "→ Creating bucket:   ${BUCKET} in ${REGION}"

# Create the bucket (us-east-2 requires LocationConstraint)
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION" \
  2>/dev/null || echo "  (bucket already exists — skipping create)"

# Versioning: allows rolling back to a previous state file if corrupted
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

# Encryption at rest (AES-256 = SSE-S3, no extra cost, no KMS key needed)
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      },
      "BucketKeyEnabled": true
    }]
  }'

# Block all public access — state files contain sensitive infra details
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo ""
echo "✅ Bootstrap complete."
echo "   Bucket : s3://${BUCKET}"
echo "   Key    : ecom/eks/terraform.tfstate"
echo ""
echo "Next steps:"
echo "  cd terraform/"
echo "  terraform init"
