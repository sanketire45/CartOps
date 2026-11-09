# =============================================================================
#  sloth.tf — Task M6: SLO engine (Sloth operator, PromServiceLevel CRs)
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        helm repo add sloth https://slok.github.io/sloth
#        helm install sloth sloth/sloth -n sloth --create-namespace \
#          --set serviceMonitor.enable=true
#
#  📖  WHAT IT DOES (one Helm release, two things on-cluster):
#        • Installs the Sloth CRDs — PrometheusServiceLevel + SLOs
#        • Installs the Sloth controller — a pod that watches those CRs
#          and generates one PrometheusRule per SLO (recording rules +
#          4-alert ladder) into the SAME namespace as the CR.
#
#  🏗️  WHY AN OPERATOR, NOT 'sloth generate' IN CI:
#        CI approach is fine for 1–3 SLOs — you commit the generated
#        PrometheusRule YAML and review it. Operator wins at 10+ services:
#          - SLOs live as 20-line CRs, fully GitOps-managed.
#          - One edit to a target → rules regenerate, no PR churn on
#            auto-generated rule YAML.
#          - The operator also exposes its own health metrics (scraped
#            via the ServiceMonitor below) → we alert if generation fails.
#
#  🪝  WHERE THE GENERATED RULES LAND:
#        Operator writes the PrometheusRule into the CR's namespace.
#        Our PromServiceLevels live in `observability` (see GitOps/slos/),
#        so the rules land there, right next to the Prometheus that picks
#        them up via `ruleSelectorNilUsesHelmValues: false` (set in
#        kube-prometheus-stack-values.yaml, same trick as ServiceMonitor
#        selection).
#
#  📏  THE 4-ALERT LADDER SLOTH GENERATES (Google SRE pattern):
#        severity  short win  long win  burn rate  catches
#        ─────────────────────────────────────────────────────────────
#        page      5m         1h        14.4×      fast disaster
#        page      30m        6h        6×         sustained outage
#        ticket    2h         1d        3×         slow drift
#        ticket    6h         3d        1×         background drift
#        Both windows in a row must agree → kills flappy single-window
#        pages. 20 lines of SLO YAML produces ~300 lines of PromQL.
#
#  🧪  VERIFY AFTER APPLY:
#        kubectl get pods -n sloth
#        kubectl get crd | grep sloth
#        # after GitOps/slos sync:
#        kubectl get prometheusservicelevel -n observability
#        kubectl get prometheusrule -n observability | grep sloth
# =============================================================================

resource "helm_release" "sloth" {
  name       = "sloth"
  repository = "https://slok.github.io/sloth"
  chart      = "sloth"
  # Pin version — latest at time of writing is 0.16.0. CRD schema (PromServiceLevel
  # v1) has been stable since 0.12, so our SLO CRs under GitOps/slos/ work here.
  version = "0.16.0"

  namespace        = "sloth"
  create_namespace = true

  values = [yamlencode({
    # Expose the operator's own metrics (slo_generator_generations_total etc.)
    # so we can alert on "SLO generation broken" in M8. Prometheus picks this
    # ServiceMonitor up thanks to the `serviceMonitorSelectorNilUsesHelmValues: false`
    # knob on kube-prometheus-stack.
    serviceMonitor = {
      enable = true
    }

    # Sloth ships a set of community SLI plugins (pre-written availability /
    # latency templates). We don't rely on them yet — our SLO CRs inline the
    # raw PromQL — but enabling them is free and lets us swap to the shorthand
    # later: `sli: plugin: sloth-common/http-availability`.
    commonPlugins = {
      enabled = true
    }
  })]

  # Order of operations:
  #   - Prometheus Operator CRDs must exist (Sloth creates PrometheusRule CRs)
  depends_on = [
    helm_release.kube_prometheus_stack,
  ]
}
