# =============================================================================
#  tempo.tf — M14: Grafana Tempo — distributed trace backend
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        aws s3api create-bucket --bucket ecom-tempo-traces-<account-id> --region us-east-2
#        eksctl create iamserviceaccount --name tempo --namespace observability \
#          --attach-policy-arn <tempo-s3-policy> --approve
#        helm install tempo grafana/tempo -n observability -f tempo-values.yaml
#
#  📖  WHAT IT DOES:
#    1. S3 bucket   — cheap object storage for trace chunks (30-day expiry).
#                     Tempo's index (which trace is in which S3 block) lives on
#                     a small PVC; the bulk data (spans) lives in S3.
#                     Cost: ~$0.023/GB/month vs ~$0.10/GB/month for EBS.
#    2. IRSA role   — Tempo pod gets AWS identity without static credentials.
#                     Locked to: system:serviceaccount:observability:tempo only.
#    3. Helm install — monolithic Tempo (single process). Right-sized for dev.
#                     Prod: grafana/tempo-distributed (ingestor/querier split).
#    4. Grafana DS  — ConfigMap labeled grafana_datasource=1 so Grafana's
#                     sidecar auto-provisions the Tempo datasource. No clicking.
#
#  🔗  OTel gateway wiring (otel-gateway-values.yaml):
#        exporters.otlp/tempo.endpoint: tempo.observability.svc.cluster.local:4317
#        service.pipelines.traces.exporters: [otlp/tempo]
#
#  🧪  VERIFY AFTER APPLY:
#        kubectl get pods -n observability -l app.kubernetes.io/name=tempo
#        # Expect: 1/1 Running
#        kubectl port-forward -n observability svc/tempo 3100:3100
#        curl http://localhost:3100/ready
#        # Expect: "ready"
# =============================================================================

# ── (1) S3 BUCKET ─────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "tempo_traces" {
  # Account-ID suffix guarantees global uniqueness — same pattern as ecom-tfstate.
  bucket        = "ecom-tempo-traces-${data.aws_caller_identity.irsa.account_id}"
  force_destroy = true  # allow `terraform destroy` to wipe trace data in dev

  tags = {
    Project = "ecom"
    ManagedBy = "terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "tempo_traces" {
  bucket                  = aws_s3_bucket.tempo_traces.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tempo_traces" {
  bucket = aws_s3_bucket.tempo_traces.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Dev cost control: traces older than 30 days auto-delete.
# Prod: set to 90d or use Glacier tiering for cold traces.
resource "aws_s3_bucket_lifecycle_configuration" "tempo_traces" {
  bucket = aws_s3_bucket.tempo_traces.id

  rule {
    id     = "expire-old-traces"
    status = "Enabled"

    expiration {
      days = 30
    }
  }
}

# ── (2) IRSA ──────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "tempo_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    # Only the Tempo ServiceAccount in observability namespace may assume this role.
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:observability:tempo"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "tempo" {
  name               = "${var.cluster_name}-tempo-irsa"
  assume_role_policy = data.aws_iam_policy_document.tempo_trust.json
}

data "aws_iam_policy_document" "tempo_s3" {
  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.tempo_traces.arn,
      "${aws_s3_bucket.tempo_traces.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "tempo_s3" {
  name   = "${var.cluster_name}-tempo-s3"
  policy = data.aws_iam_policy_document.tempo_s3.json
}

resource "aws_iam_role_policy_attachment" "tempo_s3" {
  role       = aws_iam_role.tempo.name
  policy_arn = aws_iam_policy.tempo_s3.arn
}

# ── (3) HELM INSTALL ──────────────────────────────────────────────────────────

resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = "1.24.4"

  namespace = kubernetes_namespace.observability.metadata[0].name

  values = [
    file("${path.module}/helm-values/tempo-values.yaml")
  ]

  # Dynamic values injected via set — avoids templatefile complexity.
  set {
    name  = "tempo.storage.trace.s3.bucket"
    value = aws_s3_bucket.tempo_traces.id
  }
  set {
    name  = "tempo.storage.trace.s3.region"
    value = var.aws_region
  }
  # IRSA: annotate the ServiceAccount so the pod gets an AWS identity.
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.tempo.arn
  }

  depends_on = [
    aws_iam_role_policy_attachment.tempo_s3,
    kubernetes_namespace.observability,
  ]
}

# ── (4) GRAFANA DATASOURCE ────────────────────────────────────────────────────
# Grafana sidecar watches for ConfigMaps labeled grafana_datasource=1 in ALL
# namespaces (see kube-prometheus-stack-values.yaml sidecar.datasources config).
# It auto-provisions this datasource without any Grafana restart.

resource "kubernetes_config_map" "grafana_tempo_datasource" {
  metadata {
    name      = "grafana-tempo-datasource"
    namespace = kubernetes_namespace.observability.metadata[0].name
    labels = {
      grafana_datasource = "1"
    }
  }

  data = {
    "tempo-datasource.yaml" = <<-YAML
      apiVersion: 1
      datasources:
        - name: Tempo
          type: tempo
          uid: tempo
          access: proxy
          url: http://tempo.observability.svc.cluster.local:3200
          isDefault: false
          version: 1
          jsonData:
            httpMethod: GET
            # Service graph: query Prometheus for the service-dependency map
            # shown in Tempo's Service Graph view.
            serviceMap:
              datasourceUid: prometheus
            # Node graph view: show the trace as a DAG (Directed Acyclic Graph)
            # alongside the flame chart view.
            nodeGraph:
              enabled: true
            # Trace search: allow searching traces by service/duration/tag.
            search:
              hide: false
            # Span bar: show the duration breakdown in the trace list.
            spanBar:
              type: duration
    YAML
  }

  depends_on = [kubernetes_namespace.observability]
}
