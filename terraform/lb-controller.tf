# =============================================================================
#  lb-controller.tf  —  install the AWS Load Balancer Controller (+ its IRSA)
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        1. aws iam create-policy  --policy-name AWSLoadBalancerControllerIAMPolicy \
#             --policy-document file://iam_policy.json
#        2. eksctl create iamserviceaccount --name aws-load-balancer-controller \
#             --namespace kube-system --attach-policy-arn <that policy> --approve
#             (this makes the IRSA role + the annotated ServiceAccount)
#        3. helm install aws-load-balancer-controller eks-charts/aws-load-balancer-controller \
#             -n kube-system --set clusterName=wanderlust --set region=... --set vpcId=...
#
#  📖  WHAT IT DOES, SIMPLY:
#        Installs the controller pod that CREATES AWS load balancers (the NLB that
#        fronts NGINX, and ALBs later). Because it calls AWS APIs, it needs AWS
#        permissions — given keyless via IRSA. Four pieces below:
#          (1) TRUST policy  → "the OIDC provider may let THIS ServiceAccount assume the role"
#          (2) the ROLE      → created with that trust
#          (3) PERMISSIONS   → the official policy JSON, attached to the role
#          (4) helm install  → deploys the controller + wires its SA to the role
# =============================================================================

# (1) TRUST policy — the heart of IRSA: only the kube-system
# "aws-load-balancer-controller" ServiceAccount, federated via our OIDC provider.
data "aws_iam_policy_document" "lbc_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"] # web identity = IRSA, not a normal AWS principal
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn] # the oidc.tf provider
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# (2) the ROLE (just identity + the trust policy above — no powers yet)
resource "aws_iam_role" "lbc" {
  name               = "${var.cluster_name}-aws-lbc-irsa"
  assume_role_policy = data.aws_iam_policy_document.lbc_trust.json
}

# (3) PERMISSIONS — fetch the official policy JSON, make it a policy, attach to role
data "http" "lbc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lbc" {
  name   = "${var.cluster_name}-AWSLoadBalancerControllerIAMPolicy"
  policy = data.http.lbc_iam_policy.response_body
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name # glue: attach the permissions ↑ onto the role
  policy_arn = aws_iam_policy.lbc.arn
}

# (4) HELM install — deploy the controller; the serviceAccount annotation is what
# binds its pod identity to the IAM role above (= IRSA switched ON).
# version left to latest for learning; pin for prod:
#   helm search repo eks/aws-load-balancer-controller --versions
resource "helm_release" "aws_lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName" # the pod tags/owns AWS resources for THIS cluster
    value = aws_eks_cluster.this.name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn" # ← the IRSA link
    value = aws_iam_role.lbc.arn
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "vpcId"
    value = data.aws_vpc.default.id
  }

  depends_on = [
    aws_eks_node_group.this,            # need nodes to run the pod
    aws_iam_role_policy_attachment.lbc, # need IAM ready before it starts
  ]
}
