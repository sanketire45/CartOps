# =============================================================================
#  metrics-server.tf  —  install metrics-server (prereq for HPA + kubectl top)
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
#        helm install metrics-server metrics-server/metrics-server \
#          -n kube-system \
#          --set args[0]=--kubelet-preferred-address-types=InternalIP
#
#  📖  WHAT IT DOES:
#        Runs 1 pod in kube-system. Calls every node's kubelet on port 10250
#        and reads CPU/memory usage. Exposes the Metrics API (metrics.k8s.io).
#        HPA reads from this API. `kubectl top` reads from this API.
#        EKS does NOT ship this by default — it must be installed.
#
#  ⚙️  THE EKS-SPECIFIC ARG:
#        --kubelet-preferred-address-types=InternalIP
#        Nodes register multiple addresses in their Node object (etcd).
#        By default metrics-server may try the hostname first. On EKS the
#        kubelet TLS cert only has the InternalIP in its SANs — not the
#        hostname — so TLS fails. InternalIP always works: it is reachable
#        inside the VPC and present in the cert SANs.
#
#  🔗  NO IRSA NEEDED:
#        metrics-server only calls the kubelet API (in-cluster, port 10250).
#        It never calls any AWS API. No IAM role required.
# =============================================================================

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"

  set {
    name  = "args[0]"
    value = "--kubelet-preferred-address-types=InternalIP"
  }

  # coredns depends_on node group — this single line captures the full chain:
  # vpc_cni → nodes → coredns → metrics-server
  depends_on = [aws_eks_addon.coredns]
}

# Verify after cluster-up:
#   kubectl top nodes
#   kubectl top pods -n ecom
#   kubectl get apiservice v1beta1.metrics.k8s.io   # should show Available=True
