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

# -----------------------------------------------------------------------------
#  AMI LOOKUP — always get the latest EKS-optimized AL2023 image for our K8s version.
#
#  📖 Terraform insight — data vs resource:
#       `data` = read-only lookup of something that already EXISTS in AWS.
#       `resource` = CREATE something new. We use data here because AWS already
#       maintains this AMI in their public SSM directory — we just read its ID.
#       Hardcoding an AMI ID is a common mistake in IaC — it goes stale when AWS
#       patches the image. The SSM path always points to the latest recommended one.
# -----------------------------------------------------------------------------
data "aws_ssm_parameter" "eks_ami" {
  name = "/aws/service/eks/optimized-ami/${var.cluster_version}/amazon-linux-2023/x86_64/standard/recommended/image_id"
}

# -----------------------------------------------------------------------------
#  LAUNCH TEMPLATE — overrides kubelet max-pods from the EKS default (17 for
#  t3.medium) to 110, enabling prefix delegation to actually increase pod density.
#
#  WHY THIS IS NEEDED:
#    EKS auto-creates a managed launch template if you don't supply one. That
#    template bakes `--max-pods=17` into kubelet at node boot time based on the
#    ENI formula (3 ENIs × 6 IPs - 1 = 17). Adding more IPs via prefix delegation
#    is useless unless kubelet is also told it can schedule more pods. You MUST
#    bring your own launch template to override this — there is no other way.
#
#  AL2023 vs AL2 bootstrap:
#    AL2 (old):   /etc/eks/bootstrap.sh cluster-name --kubelet-extra-args '--max-pods=110'  (bash)
#    AL2023 (us): nodeadm NodeConfig YAML inside a MIME multipart envelope  (declarative)
#    Old tutorials all show the AL2 bash approach — it silently does nothing on AL2023.
#
#  📖 Terraform insight — lifecycle create_before_destroy:
#       Without this, Terraform tries to delete the old LT version before creating
#       the new one. The node group still references the old version → plan fails.
#       create_before_destroy = true tells Terraform: create new LT version first,
#       update the reference, THEN delete the old version. Order matters in IaC.
# -----------------------------------------------------------------------------
resource "aws_launch_template" "eks_nodes" {
  name_prefix = "${var.cluster_name}-nodes-"
  image_id    = data.aws_ssm_parameter.eks_ami.value # dynamic — never hardcode AMI IDs

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = var.node_volume_size # moved here — disk_size on node group conflicts with custom LT
      volume_type = "gp3"               # gp3 = same performance as gp2, ~20% cheaper
    }
  }

  # MIME multipart: tells EC2 "this section is a nodeadm NodeConfig, parse it as YAML"
  # Only overriding maxPods — EKS managed node groups inject cluster name/endpoint/CA automatically.
  user_data = base64encode(<<-USERDATA
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BOUNDARY=="

--==BOUNDARY==
Content-Type: application/node.eks.aws

---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  kubelet:
    config:
      maxPods: 110

--==BOUNDARY==--
USERDATA
  )

  lifecycle {
    create_before_destroy = true
  }
}

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

  instance_types = [var.node_instance_type] # t3.medium
  # disk_size removed — cannot use with custom launch_template (Terraform will error); lives in LT now

  # TIER 1 = the stable "system" base (todo #3). It runs the cluster's brain
  # (CoreDNS, LB controller, metrics-server, and later Karpenter itself).
  # ON_DEMAND = never interruptible — system pods must not sit on Spot.
  capacity_type = "ON_DEMAND"
  labels = {
    role = "system" # later (#26b) we taint this + let Karpenter run APP pods elsewhere
  }

  scaling_config {
    desired_size = var.node_desired_size # 2
    min_size     = var.node_min_size     # 2
    max_size     = var.node_max_size     # 2
  }

  # Wire our custom launch template — EKS passes this to the underlying ASG it manages.
  # Every node the ASG creates (manual scale or Cluster Autoscaler) boots using this template.
  # 📖 Terraform insight — without this block EKS silently creates its own LT and you
  #    cannot override kubelet args. Custom LT = you own the AMI + user_data + disk config.
  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
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
