# =============================================================================
#  addons.tf  —  the 5 core EKS add-ons, managed by AWS (todo #2)
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        aws eks create-addon --addon-name vpc-cni        ...
#        aws eks create-addon --addon-name kube-proxy     ...
#        aws eks create-addon --addon-name coredns        ...
#        aws eks create-addon --addon-name aws-ebs-csi-driver --service-account-role-arn <role>
#        aws eks create-addon --addon-name aws-efs-csi-driver --service-account-role-arn <role>
#
#  📖  THE WHOLE IDEA (the 🏠 house analogy):
#        cluster        = the plot of land
#        ⚡ VPC CNI      = electricity (pod networking) → MUST come before nodes
#        🚪 nodes        = the rooms (created in eks.tf; they depend_on the CNI)
#        📞 CoreDNS      = the phone book (name → IP)         ┐ these LIVE INSIDE
#        🔀 kube-proxy   = routes Service traffic to pods     │ the rooms, so they
#        📦 EBS/EFS CSI  = the "bring me a disk" delivery crew ┘ come AFTER nodes
#
#        3 add-ons (CNI, CoreDNS, kube-proxy) touch no AWS → need no permission.
#        2 add-ons (EBS/EFS CSI) make real AWS disks → each needs an ID badge
#        (an IRSA role), handed over with the `service_account_role_arn` line.
# =============================================================================


# -----------------------------------------------------------------------------
#  VERSION LOOKUPS — pick the add-on version that matches our K8s version.
#  (Instead of hardcoding a version string that might not fit K8s 1.34, we ask
#   AWS for the newest one that does. Strict prod sometimes pins exact versions.)
# -----------------------------------------------------------------------------
data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}
data "aws_eks_addon_version" "kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}
data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}
data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}
data "aws_eks_addon_version" "efs_csi" {
  addon_name         = "aws-efs-csi-driver"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}


# -----------------------------------------------------------------------------
#  ⚡ ELECTRICITY — the VPC CNI. Installed FIRST (the node group in eks.tf has
#  `depends_on = [aws_eks_addon.vpc_cni]`, so nodes only boot once this exists).
#  No AWS badge needed — it just gives pods their VPC IPs.
# -----------------------------------------------------------------------------
resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  addon_version = data.aws_eks_addon_version.vpc_cni.version

  # if a setting already exists, the managed add-on wins (upgrade-safe)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}


# -----------------------------------------------------------------------------
#  📞 🔀 FURNITURE (no badge) — CoreDNS + kube-proxy. These are pods that need a
#  room to sit in, so they wait for the nodes (`depends_on` the node group).
# -----------------------------------------------------------------------------
resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "kube-proxy"
  addon_version = data.aws_eks_addon_version.kube_proxy.version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this] # 🚪 rooms must exist first
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "coredns"
  addon_version = data.aws_eks_addon_version.coredns.version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this] # CoreDNS runs 2 pods → needs nodes
}


# =============================================================================
#  🪪 THE BADGES (IRSA) — only the CSI drivers need AWS permission.
#  Each badge = (1) WHO may wear it (trust) + (2) WHAT it can do (AWS policy).
#  Reuses the SAME OIDC provider from oidc.tf — the cluster's trusted ID office.
# =============================================================================

# ---- EBS badge ----
# (1) WHO: only the EBS CSI driver's ServiceAccount (ebs-csi-controller-sa).
data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn] # the OIDC "ID office"
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}
# the EBS badge (role) + its powers (AWS-managed policy — we don't write it)
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json
}
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---- EFS badge (identical pattern, different SA + policy) ----
data "aws_iam_policy_document" "efs_csi_trust" {
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
      values   = ["system:serviceaccount:kube-system:efs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "efs_csi" {
  name               = "${var.cluster_name}-efs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.efs_csi_trust.json
}
resource "aws_iam_role_policy_attachment" "efs_csi" {
  role       = aws_iam_role.efs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}


# -----------------------------------------------------------------------------
#  📦 THE DELIVERY CREW — EBS + EFS CSI drivers. Installed AFTER nodes, each
#  WEARING its badge via `service_account_role_arn` → allowed to make AWS disks.
#  (These unblock storage: StatefulSet MongoDB on EBS #31, shared EFS #32.)
# -----------------------------------------------------------------------------
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = data.aws_eks_addon_version.ebs_csi.version
  service_account_role_arn = aws_iam_role.ebs_csi.arn # 🪪 hand over the EBS badge

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "efs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-efs-csi-driver"
  addon_version            = data.aws_eks_addon_version.efs_csi.version
  service_account_role_arn = aws_iam_role.efs_csi.arn # 🪪 hand over the EFS badge

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

# Build order (forced by the references + depends_on above):
#   cluster → ⚡ vpc-cni → 🚪 nodes → 🔀 kube-proxy / 📞 coredns / 📦 ebs-csi / 📦 efs-csi
#
# 💡 Later option (not now): add the "eks-pod-identity-agent" add-on to use
#    EKS Pod Identity (the newer alternative to IRSA) for future workloads.
