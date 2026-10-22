# =============================================================================
#  eks.tf  —  the cluster (control plane) + the worker nodes
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        eksctl create cluster   --name=ecom --version=1.34 --without-nodegroup
#        eksctl create nodegroup --node-type=c7i-flex.large --nodes=2 --node-volume-size=20
#
#  📖  WHAT IT DOES, SIMPLY:
#        A cluster = TWO halves:
#          1. CONTROL PLANE (the brain: API server, scheduler, etcd) → AWS runs &
#             hides it; you never SSH in.           → resource aws_eks_cluster
#          2. NODEGROUP (the muscle: real EC2 VMs that run your pods)
#                                                    → resource aws_eks_node_group
#        A brain with no nodes can run nothing — that's why there are two pieces.
#        We reuse the account's DEFAULT VPC (it already has subnets in 2+ AZs,
#        which EKS requires). `data` = just LOOK UP existing things, don't create.
# =============================================================================

# Current AWS account ID — used in outputs (ECR base URI).
data "aws_caller_identity" "current" {}

# Look up the default VPC + its subnets to place the cluster in (>= 2 AZs needed).
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---- THE CLUSTER (control plane) ----
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn # wears the cluster role from eks-iam.tf

  # Don't let EKS drop in its own "self-managed" CNI/CoreDNS/kube-proxy.
  # WE manage ALL add-ons ourselves as proper managed add-ons (see addons.tf).
  bootstrap_self_managed_addons = false

  # WHO may reach the cluster API, and HOW that access is managed (todo #4).
  #   authentication_mode = "API"  → modern EKS Access Entries ONLY (no aws-auth
  #     ConfigMap). Declarative, auditable, and you can't lock yourself out with a
  #     bad `kubectl edit configmap aws-auth`. (other options: CONFIG_MAP, API_AND_CONFIG_MAP)
  #   bootstrap_cluster_creator_admin_permissions = true → the IAM identity that
  #     runs `terraform apply` (your Mac) automatically becomes cluster-admin.
  #     THIS is why kubectl works from your Mac but a different box got "Unauthorized".
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids             = data.aws_subnets.default.ids
    endpoint_public_access = true # so kubectl from your laptop can reach the API
  }

  # build the role's policy first, THEN the cluster
  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# ---- THE NODEGROUP (worker EC2s) ----
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name # also makes TF build cluster first
  node_group_name = "${var.cluster_name}-system"
  node_role_arn   = aws_iam_role.eks_node.arn # wears the node role from eks-iam.tf
  subnet_ids      = data.aws_subnets.default.ids

  instance_types = [var.node_instance_type] # c7i-flex.large
  disk_size      = var.node_volume_size     # 20 GB per node

  # TIER 1 = the stable "system" base (todo #3). It runs the cluster's brain
  # (CoreDNS, LB controller, metrics-server, and later Karpenter itself).
  # ON_DEMAND = never interruptible — system pods must not sit on Spot.
  capacity_type = "ON_DEMAND"
  labels = {
    role = "system" # later (#26b) we taint this + let Karpenter run APP pods elsewhere
  }

  scaling_config {
    desired_size = var.node_desired_size # 2  (small, fixed base — autoscaler comes in #26)
    min_size     = var.node_min_size     # 2
    max_size     = var.node_max_size     # 2
  }

  # No SSH (remote_access) block on purpose: EKS nodes are managed via the API,
  # not SSH — and leaving it out keeps this state independent of the Jenkins box.

  # attach node permissions BEFORE the nodes boot & try to join
  # AND install the ⚡ CNI (networking) first — a node with no CNI stays NotReady.
  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_eks_addon.vpc_cni, # ⚡ electricity before the rooms (see addons.tf)
  ]
}

# Build order (enforced by the references above):
#   IAM roles + policies  →  cluster  →  nodegroup
# After apply: run the update-kubeconfig command (outputs.tf), then `kubectl get nodes`.

# -----------------------------------------------------------------------------
#  GRANTING ADDITIONAL ACCESS (todo #4 — Access Entries, modern approach)
#  Your Mac is already cluster-admin (creator bootstrap above).
#  To grant access to another IAM identity (CI role, teammate):
#    1. Set var.extra_admin_role_arn in terraform.tfvars (or leave "" to skip)
#    2. Uncomment the two blocks below
#
#  WHY NOT aws-auth ConfigMap?
#    aws-auth is a K8s ConfigMap — a bad YAML edit locks you out of the cluster
#    entirely. Access Entries are pure AWS API calls: even a misconfigured entry
#    is fixable from the AWS console without kubectl. Audited in CloudTrail.
#
# resource "aws_eks_access_entry" "extra_admin" {
#   cluster_name  = aws_eks_cluster.this.name
#   principal_arn = var.extra_admin_role_arn  # IAM role ARN (set in terraform.tfvars)
#   type          = "STANDARD"
# }
#
# resource "aws_eks_access_policy_association" "extra_admin" {
#   cluster_name  = aws_eks_cluster.this.name
#   principal_arn = aws_eks_access_entry.extra_admin.principal_arn
#   policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
#   access_scope { type = "cluster" } # narrow to a namespace: type = "namespace", namespaces = ["ecom"]
# }
# -----------------------------------------------------------------------------
