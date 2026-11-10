# =============================================================================
#  kube-prometheus-stack.tf — Task M3: metrics plane (Prometheus + Grafana +
#                                       Alertmanager + node-exporter + KSM)
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
#        helm install kube-prom-stack prometheus-community/kube-prometheus-stack \
#          -n observability \
#          -f kube-prometheus-stack-values.yaml
#
#  📖  WHAT IT DOES (one Helm release, ~8 things):
#        • Prometheus Operator — manages Prometheus/Alertmanager via CRDs
#        • Prometheus server    — the TSDB + PromQL engine
#        • Grafana              — dashboards UI + ~150 pre-built K8s dashboards
#        • Alertmanager         — alert routing (wired for Slack in M7)
#        • node-exporter DS     — OS metrics (one pod per node)
#        • kube-state-metrics   — K8s object state (pods, deployments, HPAs)
#        • Default ServiceMonitors for coredns/kubelet/apiserver
#        • ~60 default alert rules + ~150 dashboards for cluster health
#
#  🏗️  TWO METRIC-INGESTION PATHS INTO THE SAME PROMETHEUS:
#        1. NATIVE SCRAPE (Prometheus pulls):
#             Prometheus → node-exporter (OS metrics)
#             Prometheus → kube-state-metrics (K8s state)
#             Prometheus → cAdvisor via kubelet (container metrics)
#           These exporters have STANDARD metric names that every community
#           dashboard references — we do NOT route them through OTel.
# 
#        2. OTel PUSH (apps push via gateway):
#             Spring Boot → OTel Java agent → local OTel agent → OTel gateway
#               → prometheusremotewrite exporter → Prometheus
#           This is where app metrics (http.server.request.duration, jvm.*)
#           land. Enabled by the `enableRemoteWriteReceiver: true` knob in
#           the values file, PLUS uncommenting the exporter in the gateway.
#
#  🎚️  THE ONE SELECTOR KNOB THAT MATTERS AT SCALE:
#        serviceMonitorSelectorNilUsesHelmValues: false
#        Without it, Prometheus only picks up ServiceMonitors labeled with
#        the chart release name — a huge footgun. With false, Prometheus
#        watches ALL ServiceMonitors cluster-wide → services onboard by
#        LABEL + ServiceMonitor, not by chart edits. The "50+ services" win.
#
#  💾  STORAGE — 1d retention, 2Gi gp2 for dev:
#        Retention set to 1 day → tiny disk footprint, perfect for daily
#        apply/destroy cycles. Production would be 15d–30d + Thanos sidecar
#        → S3 for long-term + HA + global query (task M4).
#        StorageClass gp2 is EKS's default; migrate to gp3 at task #31.
#
#  🧪  VERIFY AFTER APPLY:
#        kubectl get pods -n observability -l app.kubernetes.io/part-of=kube-prometheus-stack
#        kubectl get prometheus,alertmanager,servicemonitor -n observability
#        kubectl port-forward -n observability svc/kube-prom-stack-grafana 3000:80
#        # Browser → http://localhost:3000 — admin / prom-operator
#        kubectl port-forward -n observability svc/kube-prom-stack-kube-prome-prometheus 9090:9090
#        # Browser → http://localhost:9090/targets — all scrape targets UP
# =============================================================================

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prom-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  # Pin the chart version — CRD schema changes between majors can break
  # existing ServiceMonitor/PrometheusRule CRs. Upgrade deliberately.
  version = "65.3.1"

  namespace = kubernetes_namespace.observability.metadata[0].name

  # 10-minute timeout — this chart creates a lot (CRDs, Prometheus StatefulSet,
  # Grafana Deployment, Alertmanager StatefulSet, DaemonSet, Services, etc.).
  # The default 5 min sometimes trips on EBS PVC binding.
  timeout = 600

  values = [
    file("${path.module}/helm-values/kube-prometheus-stack-values.yaml")
  ]

  # Order of operations:
  #   - EKS cluster + addons (coredns) ready
  #   - observability namespace exists
  #   - EBS CSI driver installed (for the Prometheus PVC)
  #   - gp3 StorageClass exists (Prometheus CR references it; absence of the
  #     StorageClass causes the Operator to reconcile-fail with "storage
  #     class gp3 does not exist" and the StatefulSet is never created).
  depends_on = [
    aws_eks_addon.coredns,
    aws_eks_addon.ebs_csi,
    kubernetes_namespace.observability,
    kubernetes_storage_class.gp3,
  ]
}

output "grafana_access" {
  description = "Port-forward then open in browser: kubectl port-forward -n observability svc/kube-prom-stack-grafana 3000:80"
  value       = "http://localhost:3000  (admin / prom-operator)"
}

output "prometheus_access" {
  description = "Port-forward then open in browser: kubectl port-forward -n observability svc/kube-prom-stack-kube-prome-prometheus 9090:9090"
  value       = "http://localhost:9090"
}
