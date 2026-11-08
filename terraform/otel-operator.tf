# =============================================================================
#  otel-operator.tf — Task M1/M2 prereq: install the OpenTelemetry Operator
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
#        helm install opentelemetry-operator open-telemetry/opentelemetry-operator \
#          -n opentelemetry-operator-system --create-namespace \
#          --set admissionWebhooks.certManager.enabled=false \
#          --set admissionWebhooks.autoGenerateCert.enabled=true
#
#  📖  WHAT IT DOES:
#        Installs the OpenTelemetry Operator — a Kubernetes controller that
#        watches two CRDs:
#          • OpenTelemetryCollector  → deploys OTel Collector pods from a spec
#                                      (we could use this instead of the raw
#                                       Helm chart; we chose Helm for M1 so the
#                                       config lives in values.yaml)
#          • Instrumentation         → used by M2: auto-inject the OTel Java
#                                       agent into Spring Boot pods via a
#                                       single pod annotation, zero code change
#        The Operator also runs a MUTATING ADMISSION WEBHOOK that rewrites pod
#        specs at admission time to add the init container that drops in the
#        agent.
#
#  🔐  WEBHOOK TLS — the "why two cert knobs":
#        Any mutating admission webhook in Kubernetes MUST serve HTTPS with a
#        cert the API server trusts. Two options:
#          1) cert-manager generates and rotates the cert (prod-grade) — but
#             cert-manager is task #36, not installed yet.
#          2) The Operator generates a self-signed cert on install and patches
#             the webhook CA bundle itself — fine for dev/learning.
#        We pick option 2 now; switch to cert-manager when #36 lands.
#
#  🏷️  WHY IT LIVES IN ITS OWN NAMESPACE:
#        Platform infra (opentelemetry-operator-system) stays separated from
#        the observability data pipeline (observability) and apps (ecom).
#        Lets us apply different ResourceQuota / NetworkPolicy / PSS labels.
#
#  🔗  NO IRSA NEEDED:
#        The Operator only talks to the Kubernetes API in-cluster. It needs
#        RBAC on pods/namespaces/CRDs (the chart creates these automatically)
#        but NO AWS calls at all — no IAM role.
#
#  📦  WHAT GETS INSTALLED:
#        • 1 Deployment (opentelemetry-operator)
#        • 2 CRDs (OpenTelemetryCollector, Instrumentation)
#        • 1 MutatingWebhookConfiguration + ValidatingWebhookConfiguration
#        • ServiceAccount + ClusterRole + ClusterRoleBinding
#        Total pod count: 1 (small — single replica; HA comes via leader election)
#
#  🧪  VERIFY AFTER APPLY:
#        kubectl get pods -n opentelemetry-operator-system
#        kubectl get crd | grep opentelemetry
#        # Expect: opentelemetrycollectors.opentelemetry.io
#        #         instrumentations.opentelemetry.io
#        kubectl get mutatingwebhookconfiguration | grep opentelemetry
# =============================================================================

resource "helm_release" "otel_operator" {
  name       = "opentelemetry-operator"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-operator"
  # Pin the version — NEVER use latest. A CRD schema bump can break every
  # Instrumentation / OpenTelemetryCollector CR we have. Version-pinning is
  # table-stakes for IaC. Upgrade deliberately, tested in dev first.
  version = "0.68.3"

  namespace        = "opentelemetry-operator-system"
  create_namespace = true

  # ── Webhook cert strategy — self-signed until cert-manager (task #36) lands
  # autoGenerateCert generates a cert at install and patches the webhook's
  # caBundle field automatically. Lifetime: 1 year; chart handles rotation
  # on helm upgrade.
  set {
    name  = "admissionWebhooks.certManager.enabled"
    value = "false"
  }
  set {
    name  = "admissionWebhooks.autoGenerateCert.enabled"
    value = "true"
  }

  # ── Default image for OpenTelemetryCollector CRs that don't specify one.
  # We don't use the CR in M1 (we deploy Collectors via Helm), but setting a
  # sane default matters for M2 — the Instrumentation CRD may create sidecar
  # Collectors in some patterns.
  set {
    name  = "manager.collectorImage.repository"
    value = "otel/opentelemetry-collector-k8s"
  }

  # ── Operator depends on CoreDNS (for webhook DNS lookups from the API
  # server) and metrics-server (same pattern as other platform installs).
  depends_on = [aws_eks_addon.coredns]
}

output "otel_operator_namespace" {
  description = "Where the OTel Operator lives. Verify: kubectl get pods -n opentelemetry-operator-system"
  value       = helm_release.otel_operator.namespace
}
