# =============================================================================
#  argocd.tf  —  install ArgoCD (the GitOps delivery engine)
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        kubectl create namespace argocd
#        helm install argocd argo/argo-cd -n argocd
#        (the classic tutorial way was: kubectl apply -n argocd -f install.yaml)
#
#  📖  WHAT IT DOES, SIMPLY:
#        Installs ArgoCD (its ~7 pods) into the argocd namespace. ArgoCD then
#        watches your Git repo and deploys the app for you. We bootstrap it with
#        Terraform (the industry pattern) instead of installing by hand.
#
#        ⚠️ This installs the CONTROLLER only. The ArgoCD "Application" object
#        (which points at your repo) is NOT here — its CRD doesn't exist at plan
#        time. Create it AFTER apply:
#            kubectl apply -f kubernetes/argocd-app.yaml
#        Pin the version for prod:   helm search repo argo/argo-cd --versions
# =============================================================================

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true

  depends_on = [aws_eks_node_group.this] # needs worker nodes to run its pods
}

# =============================================================================
#  External Secrets Operator  —  Phase 3 #8
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        helm repo add external-secrets https://charts.external-secrets.io
#        helm install external-secrets external-secrets/external-secrets \
#          -n external-secrets --create-namespace \
#          --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<role-arn>
#
#  📖  WHAT IT DOES, SIMPLY:
#        Installs the ESO controller. It watches for ExternalSecret CRs in any
#        namespace and syncs them from AWS Secrets Manager into real K8s Secrets.
#        The serviceAccount annotation wires IRSA so ESO can call AWS without
#        any static credentials.
# =============================================================================
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true

  # Wire IRSA: annotate ESO's ServiceAccount with the IAM role ARN created in
  # secrets-manager.tf so the ESO pod can call secretsmanager:GetSecretValue
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.eso.arn
  }

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.eso_secrets, # role must exist before ESO starts
  ]
}
