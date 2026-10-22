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
