# =============================================================================
#  oidc.tf  —  register the cluster's identity-issuer with IAM (enables IRSA)
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        eksctl utils associate-iam-oidc-provider \
#          --region us-east-2 --cluster wanderlust --approve
#
#  📖  WHAT IT DOES, SIMPLY:
#        A pod will later need AWS permissions (the LB controller creates NLBs).
#        The safe, keyless way is IRSA. IRSA only works if AWS is told to TRUST
#        tokens issued by this cluster. This file does exactly that — it adds an
#        "IAM → Identity providers → OpenID Connect" entry pointing at the
#        cluster's issuer URL. Think: a passport treaty — "AWS, trust passports
#        (tokens) stamped by THIS cluster." One-time trust link; nobody uses it
#        yet (the LB controller in lb-controller.tf is the first).
# =============================================================================

# Read the issuer's TLS certificate so we can pin its fingerprint (prove we're
# trusting the real issuer, not an impostor). Needs the cluster to exist first.
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# Register that issuer with IAM as a trusted OpenID Connect provider.
resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"] # the tokens are meant for AWS STS
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}
