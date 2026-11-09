# =============================================================================
#  cluster-autoscaler.tf  —  Task #26a: Cluster Autoscaler
# =============================================================================
#  WHAT:
#    Cluster Autoscaler (CA) is a pod that runs in kube-system and watches
#    for Pending pods — pods the scheduler couldn't place because all nodes
#    are full. When it sees them, it calls SetDesiredCapacity on the underlying
#    ASG to add a node. When nodes are underutilized for 10+ min it removes them.
#
#  HOW IT FINDS THE ASG:
#    CA scans ALL ASGs in the account for two specific tags:
#      k8s.io/cluster-autoscaler/enabled = true
#      k8s.io/cluster-autoscaler/<cluster-name> = owned
#    Those tags are set on the node group in eks.tf. EKS propagates them to ASG.
#
#  IRSA:
#    Same pattern as every other AWS-calling pod in this cluster.
#    CA's service account gets an annotation → AWS STS issues temp credentials
#    scoped to only what CA needs: describe + scale ASGs.
#
#  INSTALL:
#    Helm chart from kubernetes/autoscaler — same approach as KEDA.
#    Chart creates the SA, Deployment, RBAC in kube-system.
# =============================================================================

# ---------------------------------------------------------------------------
# IRSA — trust policy: only kube-system:cluster-autoscaler SA may assume this
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ca_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    # 📖 Terraform insight — two conditions required for IRSA security:
    #   :sub  → only THIS specific service account can assume the role
    #   :aud  → the token must be for STS (not another AWS service)
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${var.cluster_name}-cluster-autoscaler-irsa"
  assume_role_policy = data.aws_iam_policy_document.ca_assume.json
}

# ---------------------------------------------------------------------------
# Permissions — only what CA actually needs (least privilege)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ca_permissions" {
  statement {
    effect = "Allow"
    actions = [
      # Read — CA needs to find and inspect the ASG
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      # Write — scale up (add node) and scale down (remove node)
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      # EC2 — needed to read launch template config and instance type details
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeInstanceTypes",
    ]
    # resources = ["*"] — CA must describe across all ASGs to find the tagged one
    resources = ["*"]
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name   = "${var.cluster_name}-cluster-autoscaler-policy"
  policy = data.aws_iam_policy_document.ca_permissions.json
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# ---------------------------------------------------------------------------
# Helm — installs the CA pod into kube-system
# ---------------------------------------------------------------------------
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.46.6"
  namespace  = "kube-system"

  # Tell CA which cluster to manage and which region the ASG lives in
  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "awsRegion"
    value = var.aws_region
  }

  # Force the SA name to match the trust policy — without this, Helm generates
  # "<release>-aws-cluster-autoscaler" which doesn't match :sub in the trust policy.
  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }

  # Wire IRSA: annotate the SA the Helm chart creates with our role ARN.
  # The \\ escapes the dot so Terraform passes it as a literal key to Helm
  # (Helm uses dots as path separators — without escaping it breaks nesting).
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.cluster_autoscaler.arn
  }

  # CA must start AFTER CoreDNS — it calls the Kubernetes API to watch pods,
  # and CoreDNS must be running for in-cluster DNS to work.
  depends_on = [aws_eks_addon.coredns]
}

# ---------------------------------------------------------------------------
# Output — useful for verify step: check the role ARN is wired to the SA
# ---------------------------------------------------------------------------
output "cluster_autoscaler_irsa_role_arn" {
  value       = aws_iam_role.cluster_autoscaler.arn
  description = "Verify: kubectl describe sa cluster-autoscaler -n kube-system | grep eks.amazonaws.com/role-arn"
}
