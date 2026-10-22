# =============================================================================
#  nginx-ingress.tf  —  install the NGINX Ingress Controller
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        helm install ingress-nginx ingress-nginx/ingress-nginx \
#          -n ingress-nginx --create-namespace \
#          --set controller.service.type=LoadBalancer \
#          --set controller.service.annotations."service.beta.kubernetes.io/aws-load-balancer-type"=external \
#          --set controller.service.annotations."...nlb-target-type"=ip \
#          --set controller.service.annotations."...aws-load-balancer-scheme"=internet-facing
#
#  📖  WHAT IT DOES, SIMPLY:
#        Installs the NGINX pod that reads your ingress.yaml and routes HTTP by
#        path (/api → backend, / → frontend). Its own Service is type=LoadBalancer,
#        and the annotations tell the AWS LB Controller to give it an INTERNET-
#        FACING NLB that targets the NGINX pod IPs. So:
#            internet → NLB → NGINX pod → your ClusterIP services
#        NOTE: kubernetes/ingress-nginx was archived Mar 2026 — fine for learning;
#        for new prod prefer ALB Ingress or Gateway API. Pin the version for prod:
#            helm search repo ingress-nginx/ingress-nginx --versions
# =============================================================================

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true

  # expose the NGINX controller via a LoadBalancer Service...
  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }
  # ...and have the AWS LB Controller make it an internet-facing NLB to pod IPs
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "external"
  }
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type"
    value = "ip"
  }
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  depends_on = [helm_release.aws_lbc] # the LB controller must exist to build the NLB
}
