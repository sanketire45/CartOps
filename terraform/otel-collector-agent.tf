# =============================================================================
#  otel-collector-agent.tf — Task M1: OTel Collector in DaemonSet (agent) mode
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        kubectl create namespace observability
#        helm install otel-agent open-telemetry/opentelemetry-collector \
#          -n observability \
#          --set mode=daemonset \
#          -f otel-agent-values.yaml
#
#  📖  ROLE OF THE AGENT:
#        Runs ONE pod per node (DaemonSet). Each app pod on the node ships
#        its OTLP telemetry to the LOCAL agent on the same node (short hop,
#        no network cost). The agent batches and forwards everything to the
#        central gateway (otel-collector-gateway.tf).
#
#        Design rule — agent is LEAN. It does NOT enrich with Kubernetes
#        metadata, does NOT sample, does NOT fan out to backends. All heavy
#        work lives on the gateway. If the agent OOMs it takes down every
#        app pod's telemetry on that node; keep it minimal.
#
#  🌉  WHY DAEMONSET + CENTRAL GATEWAY (not one or the other):
#        • DaemonSet-only → every app pod must know the gateway's address,
#          every backend change touches every pod's ConfigMap. Also: a slow
#          backend back-pressures app pods.
#        • Gateway-only → network hop from every pod to a central service
#          over ClusterIP. Noisy neighbor if one service spams telemetry.
#        • Both (agent + gateway) → local sink absorbs bursts; gateway
#          handles enrichment + fan-out; backend changes = one gateway
#          config change, zero app changes.
#
#  📂  LOGS COLLECTION — why we skip Fluent Bit:
#        presets.logsCollection.enabled=true on the agent mounts
#        /var/log/pods and /var/log/containers from the host and enables
#        the `filelog` receiver. The agent reads container stdout logs
#        the same way Fluent Bit would — one less DaemonSet to operate.
#
#  🏷️  OBSERVABILITY NAMESPACE:
#        All observability-stack pods (Collector, Prometheus, Grafana,
#        Alertmanager, Elasticsearch, Tempo) will land here. One namespace
#        makes NetworkPolicy rules clean: "allow ecom → observability" is
#        one policy, not six.
#
#  🧪  VERIFY AFTER APPLY:
#        kubectl get pods -n observability -l app.kubernetes.io/name=opentelemetry-collector
#        # Expect: one otel-agent pod per node, all Running
#        kubectl logs -n observability -l app.kubernetes.io/instance=otel-agent --tail=20
#        # Expect: "Everything is ready. Begin running and processing data."
#        kubectl get daemonset -n observability
# =============================================================================

# ── observability namespace — created once; gateway uses this same ns ────────
# Separate kubernetes_namespace resource (not Helm create_namespace) so both
# the agent and gateway Helm releases can safely reference it without a race.
resource "kubernetes_namespace" "observability" {
  metadata {
    name = "observability"

    labels = {
      # Pod Security Standards — `privileged` on observability.
      #
      # Why NOT baseline: platform log-collector DaemonSets (OTel agent,
      # Fluent Bit, etc.) fundamentally need hostPath + hostPort —
      #   - hostPath: to read /var/log/pods/*/*/*.log from the node
      #   - hostPort: so app pods on the same node reach the agent directly
      # Both are forbidden by `baseline`. Industry pattern: trusted
      # platform-infra namespaces get `privileged`; app namespaces stay
      # `restricted`. The security boundary is the namespace.
      #
      # audit/warn stay at `restricted` — we still get warnings in events
      # and audit logs if anything in this namespace violates `restricted`.
      # That keeps visibility on anything we add here later (Prometheus,
      # Grafana, ES, Tempo) which should mostly run `restricted`-clean.
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# ── OTel Collector Helm release — DaemonSet mode ─────────────────────────────
resource "helm_release" "otel_agent" {
  name       = "otel-agent"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = "0.100.0"

  namespace = kubernetes_namespace.observability.metadata[0].name

  # ── Mode switch: SAME chart, different workload type.
  # DaemonSet → one pod per node, lean config, forwards to gateway.
  set {
    name  = "mode"
    value = "daemonset"
  }

  # ── Image: the -k8s image includes k8sattributes/kubeletstats/filelog/otlp
  # exporters — exactly what the agent needs, without the weight of -contrib.
  # Gateway uses -contrib because it needs the elasticsearch exporter (M10).
  set {
    name  = "image.repository"
    value = "otel/opentelemetry-collector-k8s"
  }
  set {
    name  = "image.tag"
    value = "0.113.0"
  }

  # ── Full receivers/processors/exporters/pipelines live in the YAML file.
  # file() reads it as a string and hands it to Helm as the --values input.
  # Keeping YAML out of HCL = syntax highlighting, yamllint, no escape hell.
  values = [
    file("${path.module}/helm-values/otel-agent-values.yaml")
  ]

  # ── Operator must exist first — the chart may create an
  # OpenTelemetryCollector CR when managed by the Operator. Gateway depends
  # on us so the namespace is ready; the Operator CRDs must be installed.
  depends_on = [
    helm_release.otel_operator,
    kubernetes_namespace.observability,
  ]
}
