#!/bin/bash
# =============================================================================
#  create-kms-key.sh  —  one-time setup, run BEFORE terraform apply
# =============================================================================
#  Creates a single KMS key for the entire ecom project.
#  Managed OUTSIDE Terraform because KMS has a 7-day minimum deletion window
#  which breaks the daily apply/destroy dev cycle.
#
#  Run once:   bash scripts/create-kms-key.sh
#  Idempotent: safe to run again — skips if alias already exists
# =============================================================================

set -e

ALIAS="alias/ecom-master"
REGION="us-east-2"

# Check if alias already exists
if aws kms describe-key --key-id "$ALIAS" --region "$REGION" &>/dev/null; then
  echo "KMS key already exists: $ALIAS — nothing to do"
  KEY_ARN=$(aws kms describe-key --key-id "$ALIAS" --region "$REGION" \
    --query 'KeyMetadata.Arn' --output text)
  echo "ARN: $KEY_ARN"
  exit 0
fi

echo "Creating KMS key..."

KEY_ID=$(aws kms create-key \
  --description "ecom master key — Secrets Manager, EBS, EFS encryption" \
  --key-usage ENCRYPT_DECRYPT \
  --region "$REGION" \
  --query 'KeyMetadata.KeyId' \
  --output text)

echo "Key created: $KEY_ID"

aws kms create-alias \
  --alias-name "$ALIAS" \
  --target-key-id "$KEY_ID" \
  --region "$REGION"

echo "Alias created: $ALIAS"

aws kms enable-key-rotation \
  --key-id "$KEY_ID" \
  --region "$REGION"

echo "Key rotation enabled"

KEY_ARN=$(aws kms describe-key --key-id "$KEY_ID" --region "$REGION" \
  --query 'KeyMetadata.Arn' --output text)

echo ""
echo "Done. KMS key is ready."
echo "ARN: $KEY_ARN"
echo "Alias: $ALIAS"
echo ""
echo "This key is NOT managed by Terraform — do not terraform destroy it."
echo "Cost: ~\$1/month flat, regardless of how many services use it."
