# =============================================================================
#  alertmanager-secret.tf — Task M7: Slack webhook as K8s Secret
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:
#        kubectl create secret generic alertmanager-slack-webhook \
#          -n observability --from-literal=url='https://hooks.slack.com/...'
#
#  📖  WHY A SECRET (not a plaintext env or ConfigMap):
#        The Slack webhook URL is effectively a bearer token — anyone with
#        it can post arbitrary messages to that channel. Three layers of
#        protection:
#          1. Value lives in secrets.auto.tfvars (gitignored, never commits).
#          2. Terraform reads it as a `sensitive` variable → masked in plans.
#          3. Stored as a K8s Secret → etcd-encrypted at rest (EKS default
#             KMS), mounted to pods only by Alertmanager's ServiceAccount.
#
#  🔗  HOW ALERTMANAGER CONSUMES IT:
#        kube-prometheus-stack mounts any secret named in
#        `alertmanagerSpec.secrets` at:
#          /etc/alertmanager/secrets/<secret-name>/<key>
#        Our config file references the URL via `api_url_file:`, which keeps
#        the URL out of Alertmanager's own generated config secret too.
#
#  🏭  PRODUCTION UPGRADE PATH:
#        For real teams: store the URL in AWS Secrets Manager, let External
#        Secrets Operator (already installed via M-earlier) sync it into
#        this K8s Secret. Rotation becomes a Secrets Manager click, zero
#        Terraform churn. We stick to direct K8s Secret here because this
#        is a dev cluster that rebuilds daily — one less moving part.
# =============================================================================

resource "kubernetes_secret" "alertmanager_slack" {
  metadata {
    name      = "alertmanager-slack-webhook"
    namespace = kubernetes_namespace.observability.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "alertmanager"
    }
  }

  # The key `url` is the filename inside the mounted directory →
  # /etc/alertmanager/secrets/alertmanager-slack-webhook/url
  data = {
    url = var.slack_webhook_url
  }

  type = "Opaque"
}
