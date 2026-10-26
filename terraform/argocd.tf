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
  wait             = false  # destroy: Application finalizer cascade-deletes ecom resources — if ArgoCD pods die mid-way it deadlocks; cluster deletion cleans up

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
# =============================================================================
#  Kyverno  —  Phase 3 #11
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        helm repo add kyverno https://kyverno.github.io/kyverno
#        helm install kyverno kyverno/kyverno -n kyverno --create-namespace
#
#  📖  WHAT IT DOES, SIMPLY:
#        Installs the Kyverno admission webhook. After this, every kubectl apply
#        / ArgoCD sync / Helm upgrade is intercepted by Kyverno before the
#        resource is written to etcd. If it violates a ClusterPolicy → blocked.
#
#        replicas=1: production uses 3 for HA. One is fine for dev/learning.
# =============================================================================
resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  version          = "3.3.7"
  wait             = false  # destroy: CRD finalizers wait for webhook that's already dying — deadlock; cluster deletion cleans up

  set {
    name  = "admissionController.replicas"
    value = "1"   # dev: 1 replica is enough; prod: 3 for HA
  }

  depends_on = [aws_eks_node_group.this]
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
  wait             = false  # destroy: ExternalSecret/ClusterSecretStore finalizers wait for ESO webhook that's dying — deadlock; cluster deletion cleans up

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
