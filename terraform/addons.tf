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

  # NetworkPolicy support DISABLED — the aws-eks-nodeagent (Network Policy
  # Agent) container crashloops silently on fresh EKS 1.34 + AL2023 nodes,
  # which starves CoreDNS of readiness, which stalls every addon install.
  # We don't use K8s NetworkPolicy resources in this project (grep -r
  # "kind: NetworkPolicy" GitOps/ → 0 hits), so losing enforcement costs
  # nothing. Flip back to "true" when adding pod-to-pod firewalls and
  # verify the agent starts cleanly on your current node AMI.
  configuration_values = jsonencode({
    enableNetworkPolicy = "false"
    # Prefix delegation: assigns a /28 block (16 IPs) per ENI slot instead of 1 IP.
    # t3.medium: 3 ENIs × 6 slots × 16 IPs = 288 IPs available (vs 17 without).
    # REQUIRES the launch template --max-pods=110 override (eks.tf) — without it
    # kubelet still caps at 17 pods regardless of how many IPs are available.
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"  # keep 1 prefix warm per ENI to avoid cold-start delays
    }
  })

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

  # CRITICAL: CoreDNS needs kube-proxy to route Service traffic. Without
  # kube-proxy, CoreDNS pods cannot reach the kubernetes Service IP
  # (10.100.0.1) to authenticate → they stay NotReady forever and the AWS
  # addon status sits in CREATING until the 20-min timeout.
  #
  # The otel-operator chart depends on CoreDNS (for its webhook DNS resolution),
  # so when boot.sh Phase 2 targets the otel_operator, Terraform drags coredns
  # into the plan — but WITHOUT this depends_on, kube-proxy is NOT pulled in
  # alongside, and the whole phase stalls.
  depends_on = [
    aws_eks_node_group.this, # CoreDNS runs 2 pods → needs nodes
    aws_eks_addon.kube_proxy, # CoreDNS needs Service routing (kube-proxy)
  ]
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


# -----------------------------------------------------------------------------
#  📌 DEFAULT STORAGE CLASS — mark the EKS-built-in gp2 StorageClass as default
#  so PVCs that don't specify storageClassName get provisioned automatically.
#
#  WHY THIS EXISTS:
#    EKS creates a gp2 StorageClass but does NOT annotate it as default. Any
#    StatefulSet PVC without an explicit storageClassName stays Pending forever
#    (Kubernetes can't guess which class to use). This annotation is the missing
#    piece. EBS CSI migration bridges gp2 (old in-tree provisioner) → CSI driver.
# -----------------------------------------------------------------------------
resource "kubernetes_annotations" "gp2_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "true"
  }
  depends_on = [aws_eks_addon.ebs_csi] # EBS CSI must be active before we rely on gp2
}


# -----------------------------------------------------------------------------
#  📌 GP3 STORAGE CLASS — Prometheus (and other write-heavy pods) want this.
#
#  WHY GP3 vs GP2:
#    - gp3: 3000 IOPS baseline, 125 MB/s throughput, ~20% cheaper per GB,
#      IOPS/throughput decoupled from size (can provision them independently).
#    - gp2: IOPS scales with size (3 IOPS/GB, min 100, burst to 3000), older gen.
#    For Prometheus TSDB (write-heavy, random I/O) gp3 is noticeably better.
#    kube-prometheus-stack's default Prometheus spec references `gp3` for storage;
#    without this StorageClass the Prometheus CR fails with
#    "storage class \"gp3\" does not exist" and the StatefulSet is never created.
#
#  VOLUMEBINDINGMODE = WaitForFirstConsumer:
#    PVC stays Pending until a pod claims it, so the EBS volume is created
#    in the SAME AZ as the pod — avoids the "volume node affinity conflict"
#    error that bites when a PVC's volume AZ doesn't match where the scheduler
#    places the pod.
# -----------------------------------------------------------------------------
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type   = "gp3"
    fsType = "ext4"
  }
  depends_on = [aws_eks_addon.ebs_csi]
}


# Build order (forced by the references + depends_on above):
#   cluster → ⚡ vpc-cni → 🚪 nodes → 🔀 kube-proxy / 📞 coredns / 📦 ebs-csi / 📦 efs-csi
#   → 📌 gp2 default annotation
#
# 💡 Later option (not now): add the "eks-pod-identity-agent" add-on to use
#    EKS Pod Identity (the newer alternative to IRSA) for future workloads.
