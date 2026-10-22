# =============================================================================
#  eks-iam.tf  —  the 2 IAM roles the cluster + nodes must "wear"
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        eksctl creates these automatically behind the scenes. Doing it manually
#        would be:
#          aws iam create-role  (cluster role)   + attach AmazonEKSClusterPolicy
#          aws iam create-role  (node role)       + attach 3 node policies
#
#  📖  WHAT IT DOES, SIMPLY:
#        AWS never lets a machine "just do things" — it must WEAR an IAM role.
#        Each role = (1) a TRUST policy "who may wear it" + (2) PERMISSION
#        policies "what it can do".
#          • CLUSTER role → worn by the EKS control plane
#          • NODE role    → worn by each worker EC2 (join cluster + pod IPs + pull images)
# =============================================================================

# ---- CLUSTER role: trust = "the EKS service may wear this" ----
data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
}

# the one managed policy the control plane needs
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---- NODE role: trust = "an EC2 instance may wear this" ----
data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
}

# the 3 things every worker node must be able to do:
resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy" # join + be managed
}
resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" # give pods VPC IPs
}
resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" # pull images
}
