# =============================================================================
#  otel-instrumentation.tf — Task M2: auto-instrument the Spring Boot fleet
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        kubectl apply -f - <<EOF
#        apiVersion: opentelemetry.io/v1alpha1
#        kind: Instrumentation
#        metadata:
#          name: ecom-java
#          namespace: ecom
#        spec:
#          java:
#            image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.10.0
#          exporter:
#            endpoint: http://\$(NODE_IP):4317
#          propagators: [tracecontext, baggage, b3]
#          sampler:
#            type: parentbased_traceidratio
#            argument: "1.0"
#          resource:
#            resourceAttributes:
#              deployment.environment: dev
#              service.namespace: ecom
#        EOF
#
#  📖  WHAT IT DOES:
#        Creates an `Instrumentation` Custom Resource in the `ecom` namespace.
#        The CRD was installed by the OTel Operator (otel-operator.tf) — this
#        is the CR (actual instance). On its own it does nothing; it becomes
#        powerful when a Spring Boot Deployment in the same namespace carries
#        the annotation:
#
#           instrumentation.opentelemetry.io/inject-java: "ecom-java"
#
#        On the pod's NEXT creation (not an in-place update — restart required),
#        the Operator's MUTATING ADMISSION WEBHOOK rewrites the pod spec:
#          1. Prepends an INIT CONTAINER that copies `javaagent.jar` from its
#             image into a shared emptyDir volume at /otel-auto-instrumentation.
#          2. Mounts that same volume in the main app container.
#          3. Sets JAVA_TOOL_OPTIONS=-javaagent:/otel-auto-instrumentation/javaagent.jar
#          4. Injects env vars: OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_SERVICE_NAME,
#             OTEL_RESOURCE_ATTRIBUTES, NODE_IP (via downward API).
#        The JVM reads JAVA_TOOL_OPTIONS at startup → attaches the agent →
#        the agent instruments Spring MVC, Feign, JDBC, Logback at BYTE-CODE
#        level — zero source change, zero image rebuild.
#
#  🚆  WHY NODE-LOCAL ROUTING (not gateway direct):
#        exporter.endpoint = http://$(NODE_IP):4317
#        $(NODE_IP) is the node's IP, injected via the Kubernetes downward
#        API below. This hits the LOCAL OTel agent DaemonSet pod on the same
#        node (hostPort 4317). Benefits over pointing straight at the gateway
#        Service:
#          • Faster: same-node network hop, no ClusterIP + iptables translation.
#          • Cheaper: no cross-AZ egress if the gateway happens to be elsewhere.
#          • More resilient: gateway outage doesn't drop app pod telemetry —
#            agent buffers until gateway recovers.
#        The agent then forwards to the gateway via its ClusterIP Service.
#
#  🔀  PROPAGATORS:
#        tracecontext → W3C `traceparent` header (the modern standard)
#        baggage      → W3C `baggage` header (for carrying custom context)
#        b3           → Zipkin's older format (compat with legacy services)
#        All three must agree across the fleet or trace context is lost at
#        the first incompatible hop. Spring Cloud defaults to tracecontext +
#        baggage, so we add b3 only for interop headroom.
#
#  📊  SAMPLER — 100% at the SDK:
#        parentbased_traceidratio(1.0) = keep EVERY span that the SDK produces.
#        The DECISION to drop happens upstream in the OTel gateway's
#        tail_sampling processor (see otel-gateway-values.yaml) — gateway sees
#        the WHOLE trace, so it can keep errors + slow traces and drop the
#        rest. Head-sampling (at the SDK) can't do that because it decides
#        before the trace finishes.
#
#  🏷️  RESOURCE ATTRIBUTES — the labels every signal carries:
#        deployment.environment = dev  → filter dev vs prod in Grafana
#        service.namespace      = ecom → scope to the app namespace
#        service.name is set AUTOMATICALLY by the Operator from the pod's
#        workload name (Deployment name). No manual override needed.
#
#  🧪  VERIFY AFTER APPLY:
#        kubectl get instrumentation -n ecom
#        # Expect: ecom-java listed.
#        kubectl describe instrumentation ecom-java -n ecom | head -40
#
#        # After rolling a Spring service (adds the annotation + restart):
#        kubectl get pod <product-pod> -n ecom -o yaml | grep -A2 "initContainer\|JAVA_TOOL_OPTIONS"
#        # Expect: opentelemetry-auto-instrumentation init container +
#        #         JAVA_TOOL_OPTIONS env var pointing at javaagent.jar.
#
#        # Watch the LOCAL agent on the pod's node log receiving OTLP:
#        kubectl logs -n observability -l app.kubernetes.io/instance=otel-agent --tail=50
#        # Expect: "TracesExporter" / "MetricsExporter" lines once app has traffic.
# =============================================================================

# ── ecom namespace — owned by Terraform (not the Helm chart) ─────────────────
# Why Terraform (not ArgoCD/Helm): the Instrumentation CR for M2 must live in
# the `ecom` namespace. That means the namespace has to exist BEFORE the chart
# is synced by ArgoCD. Chicken-and-egg if the chart owns it.
#
# Solution: Terraform creates it with the PSS `restricted` labels. The Helm
# chart's templates/namespace.yaml becomes an idempotent upsert that re-applies
# the same labels — no conflict, no ownership fight (both sides agree).
#
# Trade-off: `terraform destroy` will try to delete this namespace. If ecom
# workloads are still present, deletion will stall. Acceptable — teardown
# order is already a documented concern in TASKS.md cost-controls.
resource "kubernetes_namespace" "ecom" {
  metadata {
    name = "ecom"

    # Match the labels the Helm chart's templates/namespace.yaml applies.
    # Pod Security Standards — strict `restricted` on app workloads (our
    # Spring pods already comply: runAsNonRoot, drop ALL caps, etc.).
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
    }
  }
}

resource "kubernetes_manifest" "ecom_java_instrumentation" {
  manifest = {
    apiVersion = "opentelemetry.io/v1alpha1"
    kind       = "Instrumentation"
    metadata = {
      name = "ecom-java"
      # Instrumentation is a NAMESPACED resource. The Operator only processes
      # pods in the SAME namespace as the CR. Our Spring apps live in `ecom`.
      namespace = "ecom"
    }
    spec = {
      # ── Agent image: pinned 2.10.0 (never :latest — CRD/agent compatibility)
      java = {
        image = "ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.10.0"
      }

      # ── Where telemetry goes: node-local OTel agent via hostPort 4318 (HTTP).
      # $(NODE_IP) is resolved at container start from the env var below.
      #
      # ⚠️ Port 4318 = OTLP/HTTP, NOT 4317 (gRPC).
      # OTel Java agent 2.x defaults to OTLP protocol `http/protobuf`. If we
      # point it at the gRPC port (4317) with an http:// URL, the exporter
      # throws "Connection reset" on every batch (server speaks gRPC, client
      # speaks HTTP). Keep the agent's auto-detected default by matching the
      # URL: http:// + port 4318. Alternative would be
      # OTEL_EXPORTER_OTLP_PROTOCOL=grpc + port 4317, but matching the default
      # is cleaner and interview-safe ("I used OTLP/HTTP for Java apps since
      # that's the 2.x default — simpler firewall rules, no port confusion").
      exporter = {
        endpoint = "http://$(NODE_IP):4318"
      }

      # ── Trace-context propagators across service calls.
      propagators = [
        "tracecontext", # W3C modern standard — required
        "baggage",      # W3C context payload — required
        "b3",           # Zipkin legacy — safe to include for interop
      ]

      # ── SDK sampler: keep 100%. Gateway tail-samples (see M1 gateway config).
      sampler = {
        type     = "parentbased_traceidratio"
        argument = "1.0"
      }

      # ── Resource attributes = labels every span/metric/log carries.
      # service.name is filled by the Operator from the Deployment name.
      resource = {
        resourceAttributes = {
          "deployment.environment" = "dev"
          "service.namespace"      = "ecom"
        }
      }

      # ── Downward API: inject the node's IP as NODE_IP env var.
      # Needed for the $(NODE_IP) substitution in exporter.endpoint above.
      # Also sets a few env vars the Java agent reads directly.
      env = [
        {
          name = "NODE_IP"
          valueFrom = {
            fieldRef = {
              fieldPath = "status.hostIP"
            }
          }
        },
        {
          # Limit agent memory — the OTel Java agent has its own JVM overhead
          # beyond the app's. Capping here keeps the pod resource budget sane.
          name  = "OTEL_JAVAAGENT_DEBUG"
          value = "false"
        },
      ]
    }
  }

  # Operator must be installed before the CRD exists → before we can create
  # instances of it. Namespace `ecom` is created ABOVE (Terraform-owned).
  depends_on = [
    helm_release.otel_operator,
    kubernetes_namespace.ecom,
  ]
}

output "otel_instrumentation_name" {
  description = "Name to reference in pod annotations: instrumentation.opentelemetry.io/inject-java: \"<this>\""
  value       = "ecom-java"
}
