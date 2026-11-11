# =============================================================================
#  otel-collector-gateway.tf — Task M1: OTel Collector in Deployment mode
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        helm install otel-gateway open-telemetry/opentelemetry-collector \
#          -n observability \
#          --set mode=deployment --set replicaCount=2 \
#          -f otel-gateway-values.yaml
#
#  📖  ROLE OF THE GATEWAY:
#        Central Deployment (2 replicas) that receives telemetry from every
#        agent in the fleet. Does the heavy work:
#          1. memory_limiter       — gate: never OOM, back-pressure instead
#          2. k8sattributes        — enrich signals with pod/ns/node/deploy
#          3. tail_sampling (traces only) — keep errors + slow, sample rest
#          4. batch                — bundle before export (fewer backend calls)
#          5. fan-out to backends  — metrics → Prometheus · logs → ES ·
#                                    traces → Tempo (+ Jaeger optional)
#
#        Agents are lean; gateway is where the real logic sits. Changing a
#        backend endpoint = one line in this values file. Zero app change.
#
#  🚫  WHY NOT ONE COLLECTOR DOING BOTH ROLES:
#        Keeping it split means node-local receive (agent) cannot block on
#        the gateway. If the gateway is slow or restarts, agents buffer and
#        retry; app pods never notice. One combined Collector = every app
#        pod sees gateway outages directly.
#
#  🔀  INITIAL EXPORTER = DEBUG ONLY:
#        Prometheus (M3), Elasticsearch (M10), Tempo (M14) don't exist yet.
#        For M1 the gateway exports to the `debug` exporter — prints OTLP
#        to stdout. Verify end-to-end flow (app → agent → gateway → stdout)
#        with `kubectl logs`. As each backend lands (M3/M10/M14), ADD its
#        exporter to this values file and the pipeline — no code change.
#
#  🏗️  HA DESIGN:
#        replicaCount=2 → one can restart without data loss. Agents retry.
#        PodAntiAffinity (soft) spreads them across nodes. Later: HPA on
#        memory + a PodDisruptionBudget (minAvailable=1).
#
#  🧪  VERIFY AFTER APPLY:
#        kubectl get pods -n observability -l app.kubernetes.io/instance=otel-gateway
#        # Expect: 2 pods Running
#        kubectl logs -n observability -l app.kubernetes.io/instance=otel-gateway --tail=50
#        # Once an app sends telemetry (M2), expect "TracesExporter ..."
#        kubectl get svc -n observability otel-gateway-opentelemetry-collector
#        # Expect: ClusterIP exposing :4317 (OTLP/gRPC) + :4318 (OTLP/HTTP)
#
#  🧯  SMOKE TEST BEFORE M2 (send fake OTLP into the gateway):
#        kubectl run tgen --rm -it -n observability \
#          --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
#          --restart=Never -- traces \
#          --otlp-endpoint otel-gateway-opentelemetry-collector:4317 \
#          --otlp-insecure --traces 5
#        # Then: kubectl logs -n observability -l app.kubernetes.io/instance=otel-gateway
#        # Expect: 5 traces printed by the debug exporter
# =============================================================================

resource "helm_release" "otel_gateway" {
  name       = "otel-gateway"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = "0.100.0"

  namespace = kubernetes_namespace.observability.metadata[0].name

  # ── Mode switch: Deployment (NOT daemonset).
  # Same chart as the agent, different workload type.
  set {
    name  = "mode"
    value = "deployment"
  }

  # ── 1 replica — dev-mode. Cost compromise: on our 3-node t3.medium
  # cluster, a second gateway pod (512Mi) alone forces cluster-autoscaler
  # to add a 4th node. If this pod restarts, agents buffer in memory for
  # ~5-10s before retrying — acceptable for dev. Prod flips back to 2
  # for ReplicaSet-survives-one-restart HA.
  set {
    name  = "replicaCount"
    value = "1"
  }

  # ── Image: -contrib — needed because the gateway will eventually export
  # to Elasticsearch (M10). The elasticsearch exporter is NOT in the -k8s
  # image, only in -contrib. Pay the image size tax on 2 pods, not 100.
  set {
    name  = "image.repository"
    value = "otel/opentelemetry-collector-contrib"
  }
  set {
    name  = "image.tag"
    value = "0.113.0"
  }

  values = [
    file("${path.module}/helm-values/otel-gateway-values.yaml")
  ]

  # wait=false: the gateway pod can't start until ECK creates the
  # ecom-logs-es-elastic-user secret (after ArgoCD deploys Elasticsearch).
  # Waiting here would always timeout. boot.sh waits for the secret separately
  # and then restarts the gateway deployment to pick up the real password.
  wait    = false
  timeout = 900

  depends_on = [
    helm_release.otel_operator,
    kubernetes_namespace.observability,
  ]
}

output "otel_gateway_endpoint" {
  description = "In-cluster OTLP endpoint for the OTel gateway. Point apps and agents here."
  value       = "otel-gateway-opentelemetry-collector.${kubernetes_namespace.observability.metadata[0].name}.svc.cluster.local:4317"
}
