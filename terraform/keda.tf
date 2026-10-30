# =============================================================================
#  keda.tf — Task #25: KEDA operator + IRSA for SQS-based scale-to-zero
# =============================================================================
#  WHAT THIS DOES:
#    Installs KEDA (Kubernetes Event-Driven Autoscaler) via Helm.
#    KEDA watches the order-events SQS queue depth and scales notification-worker
#    between 0 and 5 replicas — 0 when queue is empty, up to 1 pod per 5 messages.
#
#  WHY NOT PLAIN HPA:
#    HPA minimum is 1 — it can never scale to zero.
#    KEDA reads an external metric (SQS depth) instead of pod CPU/memory,
#    so it can scale the deployment all the way to 0 replicas when idle.
#
#  IRSA DESIGN — operator owns the IAM identity:
#    identityOwner: operator in ScaledObject means KEDA's own SA (keda-operator
#    in kube-system) calls sqs:GetQueueAttributes to poll queue depth.
#    The notification-worker pods never call GetQueueAttributes themselves —
#    their IRSA role (in irsa.tf) only needs ReceiveMessage + DeleteMessage.
#    Separation of concerns: scaling logic ≠ message consumption logic.
#
#  VERIFY AFTER APPLY:
#    kubectl get pods -n kube-system | grep keda
#    kubectl get scaledobject -n ecom
#    kubectl get hpa -n ecom           # KEDA creates keda-hpa-notification-worker
#    kubectl describe scaledobject notification-worker-scaledobject -n ecom
# =============================================================================

# ── KEDA operator IRSA role ───────────────────────────────────────────────────
# data block reuses aws_caller_identity.irsa defined in irsa.tf — same provider

data "aws_iam_policy_document" "keda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    # Lock to keda-operator SA in kube-system — Helm creates this SA with the role ARN annotation
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:keda-operator"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keda_operator" {
  name               = "${var.cluster_name}-keda-operator-irsa"
  assume_role_policy = data.aws_iam_policy_document.keda_assume.json
}

# GetQueueAttributes — reads ApproximateNumberOfMessages to decide replica count
# Scoped to order-events only — KEDA cannot inspect any other queue
data "aws_iam_policy_document" "keda_permissions" {
  statement {
    effect  = "Allow"
    actions = ["sqs:GetQueueAttributes"]
    resources = [
      "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.irsa.account_id}:order-events"
    ]
  }
}

resource "aws_iam_policy" "keda_operator" {
  name   = "${var.cluster_name}-keda-operator-policy"
  policy = data.aws_iam_policy_document.keda_permissions.json
}

resource "aws_iam_role_policy_attachment" "keda_operator" {
  role       = aws_iam_role.keda_operator.name
  policy_arn = aws_iam_policy.keda_operator.arn
}

# ── KEDA Helm release ─────────────────────────────────────────────────────────

resource "helm_release" "keda" {
  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = "2.16.0"
  namespace  = "kube-system"

  # Annotate the keda-operator SA with the IRSA role ARN.
  # The \\ escapes the dot so Helm treats it as a literal key name,
  # not a nested path separator. Without escaping, Helm splits on the dot
  # and tries to create nested keys instead of the annotation key string.
  set {
    name  = "serviceAccount.operator.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.keda_operator.arn
  }

  # KEDA CRDs (ScaledObject, TriggerAuthentication) install via Helm.
  # coredns must be up first so keda webhooks can resolve DNS.
  depends_on = [aws_eks_addon.coredns]
}

output "keda_operator_irsa_role_arn" {
  description = "IRSA role ARN on keda-operator SA — verify: kubectl get sa keda-operator -n kube-system -o yaml | grep role-arn"
  value       = aws_iam_role.keda_operator.arn
}
