# =============================================================================
#  irsa.tf  —  Phase 3 #9: scoped IRSA role per workload
# =============================================================================
#  One IAM role per service — each locked to its own ServiceAccount.
#  Blast radius: compromising one pod cannot access another service's AWS resources.
#
#  product-category → Secrets Manager GetSecretValue on ecom/* only
#  order-service    → SQS SendMessage on order-events only (queue created in #38)
# =============================================================================

data "aws_caller_identity" "irsa" {}

# ── product-category IRSA ─────────────────────────────────────────────────────

# Trust policy: only product-category-sa in ecom namespace can assume this role
data "aws_iam_policy_document" "product_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    # Gate 1: token must be from THIS cluster's OIDC (principals above handles this)
    # Gate 2: token sub must be exactly this ServiceAccount
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:ecom:product-category-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "product" {
  name               = "${var.cluster_name}-product-irsa"
  assume_role_policy = data.aws_iam_policy_document.product_assume.json
}

# Permission: read secrets under ecom/* only + decrypt with KMS key
data "aws_iam_policy_document" "product_permissions" {
  statement {
    effect  = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.irsa.account_id}:secret:ecom/*"
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_key.master.arn]
  }
}

resource "aws_iam_policy" "product" {
  name   = "${var.cluster_name}-product-irsa-policy"
  policy = data.aws_iam_policy_document.product_permissions.json
}

resource "aws_iam_role_policy_attachment" "product" {
  role       = aws_iam_role.product.name
  policy_arn = aws_iam_policy.product.arn
}

# ── order-service IRSA ────────────────────────────────────────────────────────

# Trust policy: only order-service-sa in ecom namespace
data "aws_iam_policy_document" "order_assume" {
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
      values   = ["system:serviceaccount:ecom:order-service-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "order" {
  name               = "${var.cluster_name}-order-irsa"
  assume_role_policy = data.aws_iam_policy_document.order_assume.json
}

# Permission: SQS SendMessage only — cannot read, delete, or manage queues
# Queue ARN uses * for now — will be locked to order-events ARN when queue is created in #38
data "aws_iam_policy_document" "order_permissions" {
  statement {
    effect  = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:GetQueueUrl",
    ]
    resources = [
      "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.irsa.account_id}:order-events"
    ]
  }
}

resource "aws_iam_policy" "order" {
  name   = "${var.cluster_name}-order-irsa-policy"
  policy = data.aws_iam_policy_document.order_permissions.json
}

resource "aws_iam_role_policy_attachment" "order" {
  role       = aws_iam_role.order.name
  policy_arn = aws_iam_policy.order.arn
}

# ── notification-worker IRSA ──────────────────────────────────────────────────
#
#  Scope: SQS consume only — ReceiveMessage + DeleteMessage + GetQueueUrl
#  Cannot SendMessage (that's order-service's role only)
#  Cannot touch any other queue — ARN locked to order-events specifically

data "aws_iam_policy_document" "notification_worker_assume" {
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
      values   = ["system:serviceaccount:ecom:notification-worker-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "notification_worker" {
  name               = "${var.cluster_name}-notification-worker-irsa"
  assume_role_policy = data.aws_iam_policy_document.notification_worker_assume.json
}

data "aws_iam_policy_document" "notification_worker_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",  # poll the queue for new messages
      "sqs:DeleteMessage",   # delete after successful processing (ack)
      "sqs:GetQueueUrl",     # resolve queue name → URL at startup
      "sqs:GetQueueAttributes", # read queue metadata (visibility timeout etc.)
    ]
    resources = [
      "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.irsa.account_id}:order-events"
    ]
  }
}

resource "aws_iam_policy" "notification_worker" {
  name   = "${var.cluster_name}-notification-worker-irsa-policy"
  policy = data.aws_iam_policy_document.notification_worker_permissions.json
}

resource "aws_iam_role_policy_attachment" "notification_worker" {
  role       = aws_iam_role.notification_worker.name
  policy_arn = aws_iam_policy.notification_worker.arn
}

# ── Outputs — paste these into values.yaml irsa section ──────────────────────
output "product_irsa_role_arn" {
  description = "Annotate product-category-sa ServiceAccount with this ARN"
  value       = aws_iam_role.product.arn
}

output "order_irsa_role_arn" {
  description = "Annotate order-service-sa ServiceAccount with this ARN"
  value       = aws_iam_role.order.arn
}

output "notification_worker_irsa_role_arn" {
  description = "Annotate notification-worker-sa ServiceAccount with this ARN"
  value       = aws_iam_role.notification_worker.arn
}
