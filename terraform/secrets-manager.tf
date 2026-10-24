# =============================================================================
#  secrets-manager.tf  —  Phase 3 #8: store DB password in AWS Secrets Manager
# =============================================================================
#  WHY:
#    mysqlPassword: "Sanket@123" was sitting in values.yaml in Git.
#    Anyone who clones the repo has the DB password.
#    This moves it to AWS Secrets Manager (encrypted, audited, rotatable).
#
#  FLOW:
#    1. This file creates the secret in AWS (encrypted with KMS)
#    2. ESO (external-secret.yaml in Helm) fetches it and writes a K8s Secret
#    3. Pods read from that K8s Secret — unchanged from before
# =============================================================================

# ── KMS key — encrypts the secret at rest ────────────────────────────────────
# Without this, Secrets Manager uses the default AWS-managed key.
# Using a customer-managed key (CMK) lets you: audit who used it in CloudTrail,
# revoke access by disabling the key, and rotate it on your schedule.
resource "aws_kms_key" "secrets" {
  description             = "KMS key for ecom Secrets Manager secrets"
  deletion_window_in_days = 7   # minimum; gives you a week to cancel accidental deletion
  enable_key_rotation     = true

  tags = { Purpose = "secrets-encryption" }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/ecom-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# ── The secret itself ─────────────────────────────────────────────────────────
# Stored as JSON so one secret can hold multiple fields (password + future keys).
# The value is set via aws_secretsmanager_secret_version below.
resource "aws_secretsmanager_secret" "mysql_password" {
  name       = "ecom/mysql-password"
  kms_key_id = aws_kms_key.secrets.key_id

  # prevent accidental deletion — must explicitly pass --force-delete-without-recovery
  # to delete this secret. Safe default for production.
  recovery_window_in_days = 7

  tags = { Service = "mysql" }
}

resource "aws_secretsmanager_secret_version" "mysql_password" {
  secret_id     = aws_secretsmanager_secret.mysql_password.id
  secret_string = jsonencode({ password = "Sanket@123" })
}

# ── IRSA role for ESO ─────────────────────────────────────────────────────────
# ESO pod needs permission to call GetSecretValue.
# IRSA = the ESO ServiceAccount (in external-secrets namespace) assumes this role
# via the cluster's OIDC provider — no static AWS keys anywhere.
#
# Trust policy: "only the ESO ServiceAccount in the external-secrets namespace
# on THIS cluster may assume this role"
data "aws_iam_policy_document" "eso_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "${var.cluster_name}-eso-irsa"
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json
}

# Permission policy: ESO can only read secrets under ecom/* — nothing else
data "aws_iam_policy_document" "eso_secrets" {
  statement {
    effect  = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:ecom/*"
    ]
  }

  # ESO needs the KMS key to decrypt the secret
  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.secrets.arn]
  }
}

resource "aws_iam_policy" "eso_secrets" {
  name   = "${var.cluster_name}-eso-secrets-policy"
  policy = data.aws_iam_policy_document.eso_secrets.json
}

resource "aws_iam_role_policy_attachment" "eso_secrets" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso_secrets.arn
}

# ── Output the role ARN — Helm needs it to annotate the ESO ServiceAccount ───
output "eso_irsa_role_arn" {
  description = "Annotate the ESO ServiceAccount with this ARN to enable IRSA"
  value       = aws_iam_role.eso.arn
}
