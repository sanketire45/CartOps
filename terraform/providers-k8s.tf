# =============================================================================
#  providers-k8s.tf  —  the "login" that lets Terraform talk to the cluster
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        aws eks update-kubeconfig --region us-east-2 --name wanderlust
#        (that command writes the cluster's address + auth into kubeconfig so
#         kubectl/helm can reach it — this file does the same for Terraform)
#
#  📖  WHAT IT DOES, SIMPLY:
#        The kubernetes + helm providers need to know HOW to reach your cluster.
#        We give them three things:
#          • host  = the cluster's API address (where to send requests)
#          • cert  = the cluster's CA cert → "is this the REAL server?" (TLS trust)
#          • token = a short-lived login token → "who am I / am I allowed?"
#        With these, every helm_release in the other files knows which cluster to
#        install into. (These read from aws_eks_cluster.this, so the cluster is
#        built first, then this connects to it.)
# =============================================================================

# A short-lived auth token for the cluster, generated from your AWS identity.
data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this.name
}

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
