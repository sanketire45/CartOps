# =============================================================================
#  sqs.tf  —  Task #38: order-events SQS queue + DLQ + CloudWatch alarm
# =============================================================================
#  FLOW:
#    order-service  →  SendMessage  →  order-events queue
#    notification-worker  →  ReceiveMessage  →  process  →  DeleteMessage
#
#  If processing fails 3× → message moves to order-events-dlq automatically.
#  CloudWatch alarm fires when DLQ depth > 0 (stuck consumer or poison message).
# =============================================================================

# ── Dead-Letter Queue (must be created BEFORE the main queue) ─────────────────
#
#  WHY DLQ FIRST:
#    The main queue's redrive policy references the DLQ ARN.
#    Terraform resolves this as a dependency automatically via
#    aws_sqs_queue.order_events_dlq.arn.
#
#  WHAT IT DOES:
#    After maxReceiveCount=3 failed processing attempts, SQS moves the
#    message here. The worker never sees it again. You inspect the DLQ
#    to debug poisoned messages without blocking live traffic.

resource "aws_sqs_queue" "order_events_dlq" {
  name                      = "order-events-dlq"
  message_retention_seconds = 1209600 # 14 days — long window to investigate failures

  tags = {
    Project = "ecom"
    Env     = "dev"
    Purpose = "dead-letter queue for order-events"
  }
}

# ── Main queue — order-events ─────────────────────────────────────────────────
#
#  KEY SETTINGS EXPLAINED:
#
#  visibility_timeout_seconds = 60
#    When notification-worker picks a message, SQS hides it for 60s.
#    If the worker doesn't delete it within 60s, SQS assumes the worker
#    crashed and re-delivers to another pod. Set this > your max
#    processing time to avoid duplicate delivery mid-processing.
#
#  message_retention_seconds = 86400 (1 day)
#    If nobody consumes a message within 1 day, it expires.
#    Short retention = cheap + forces you to fix consumer outages fast.
#
#  redrive_policy:
#    After 3 failed receive attempts (maxReceiveCount), SQS automatically
#    moves the message to the DLQ. Without this, a poison message loops
#    forever and blocks all subsequent messages in the queue.

resource "aws_sqs_queue" "order_events" {
  name                       = "order-events"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400 # 1 day

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.order_events_dlq.arn
    maxReceiveCount     = 3 # 3 failed attempts → move to DLQ
  })

  tags = {
    Project = "ecom"
    Env     = "dev"
    Purpose = "order events for notification-worker"
  }
}

# ── CloudWatch alarm — DLQ depth > 0 ─────────────────────────────────────────
#
#  ApproximateNumberOfMessagesVisible on the DLQ is the canary metric:
#    0 = everything processing cleanly
#   >0 = at least one message failed 3× — something is broken
#
#  This is the single most important SQS alarm. A message in the DLQ means
#  a real event (an order) was never processed. Alert immediately.

resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "order-events-dlq-not-empty"
  alarm_description   = "Messages in DLQ — notification-worker failed to process an order event 3 times"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.order_events_dlq.name }
  statistic           = "Sum"
  period              = 60    # check every minute
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  # Wire to an SNS topic → Slack/email in production
  # alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Project = "ecom", Env = "dev" }
}

# ── Outputs — used by irsa.tf IRSA policy + values.yaml ──────────────────────

output "order_events_queue_url" {
  description = "SQS queue URL — set as env var in order-service + notification-worker pods"
  value       = aws_sqs_queue.order_events.url
}

output "order_events_queue_arn" {
  description = "SQS queue ARN — used in IRSA IAM policy resource constraint"
  value       = aws_sqs_queue.order_events.arn
}

output "order_events_dlq_arn" {
  description = "DLQ ARN — for CloudWatch alarm and monitoring"
  value       = aws_sqs_queue.order_events_dlq.arn
}
