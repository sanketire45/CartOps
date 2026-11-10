# =============================================================================
#  eck-operator.tf — M10: Elastic Cloud on Kubernetes (ECK) operator
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        helm repo add elastic https://helm.elastic.co
#        helm install elastic-operator elastic/eck-operator \
#          -n elastic-system --create-namespace
#
#  📖  WHAT IT DOES:
#        Installs the ECK operator — Elastic's official Kubernetes operator
#        for Elasticsearch, Kibana, APM Server, Beats, Logstash, Elastic Agent,
#        and Elastic Maps Server. We use it for Elasticsearch + Kibana only.
#
#        The operator watches these CRDs:
#          • Elasticsearch       — declare an ES cluster as YAML
#          • Kibana              — declare a Kibana instance wired to an ES
#          • User / ApiKey       — declarative role management
#          • + others (Beats, Logstash, APM, etc.)
#
#        For each CR it:
#          - Creates the StatefulSet / Deployment with correct JVM tuning
#          - Generates + rotates self-signed TLS certs (per-node + CA)
#          - Seeds the `elastic` superuser Secret
#          - Handles zone-aware rolling upgrades respecting quorum
#          - Resizes storage via volume expansion (where SC allows)
#
#  🏷️  NAMESPACE CHOICE:
#        The operator runs in its own `elastic-system` namespace (Elastic's
#        convention — matches their docs and Helm chart defaults).
#        The actual Elasticsearch + Kibana workloads sit in `observability`
#        alongside Prometheus/Grafana (chosen in M10 scope decision — one
#        pane for all telemetry infra).
#
#  🔐  NO IRSA NEEDED:
#        Operator only talks to the Kubernetes API in-cluster to reconcile
#        CRDs. ES snapshot-to-S3 (future ILM work in M12) will need IRSA
#        on the ES pod's SA, but that's a workload-level role, not operator.
#
#  🧪  VERIFY AFTER APPLY:
#        kubectl get pods -n elastic-system
#        kubectl get crd | grep elastic.co
#        # Expect: elasticsearches / kibanas / users / etc.
# =============================================================================

resource "helm_release" "eck_operator" {
  name       = "elastic-operator"
  repository = "https://helm.elastic.co"
  chart      = "eck-operator"
  # Pin the version — a CRD schema bump could invalidate every ES/Kibana CR.
  # Table-stakes IaC discipline, same reasoning as the otel-operator pin.
  version = "2.14.0"

  namespace        = "elastic-system"
  create_namespace = true

  # Short timeout — the operator install is CRD + Deployment only, no PVC.
  # If it takes >3 min something is wrong (usually a webhook cert race).
  timeout = 300
  wait    = true

  # We want kube-prom-stack to be up before this (so the operator's
  # ServiceMonitor can scrape) but it's not a hard dependency. coredns is.
  depends_on = [
    aws_eks_addon.coredns,
  ]
}

output "eck_operator_namespace" {
  description = "Where the ECK operator lives. Verify: kubectl get pods -n elastic-system"
  value       = helm_release.eck_operator.metadata[0].namespace
}
