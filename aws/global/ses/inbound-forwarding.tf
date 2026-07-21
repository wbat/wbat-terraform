# SES inbound receive → sync gate → S3 → SQS → worker → Gmail + Roundcube.
#
# Cutover (no mailbox addresses in this public repo):
#   1. Set TFC sensitive var inbound_recipients (HCL list)
#   2. Populate Secrets Manager runtime-config JSON (see secret name output)
#   3. terraform apply
#   4. Remove DirectAdmin Gmail forwarders for allowlisted addresses
#   5. Point domain MX at SES inbound (see ses_inbound_mx_records output)
#   6. Test from an external account; check Gmail, Roundcube, Lambda logs
#
# Roundcube copies use SMTP submission :587 (AUTH). Port 25 from Lambda is blocked.

data "aws_region" "current" {}

locals {
  inbound_enabled   = var.enable_inbound_forwarding
  inbound_prefix    = "inbound/"
  quarantine_prefix = "quarantine/"
  # Recipients come from TFC (sensitive). nonsensitive() is required for for_each;
  # values still appear in private TFC state / SES console, never in git defaults.
  recipients = local.inbound_enabled ? nonsensitive(var.inbound_recipients) : []
  recipient_rule_names = {
    for addr in local.recipients :
    addr => "fwd-${substr(sha1(addr), 0, 10)}"
  }
  sorted_recipients = sort(local.recipients)
}

# -----------------------------------------------------------------------------
# S3
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "ses_inbound" {
  count  = local.inbound_enabled ? 1 : 0
  bucket = "tellerstech-ses-inbound-${data.aws_caller_identity.current.account_id}"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech SES Inbound Mail"
      "scm:file" = "aws/global/ses/inbound-forwarding.tf"
    },
  )
}

resource "aws_s3_bucket_public_access_block" "ses_inbound" {
  count  = local.inbound_enabled ? 1 : 0
  bucket = aws_s3_bucket.ses_inbound[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ses_inbound" {
  count  = local.inbound_enabled ? 1 : 0
  bucket = aws_s3_bucket.ses_inbound[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ses_inbound" {
  count  = local.inbound_enabled ? 1 : 0
  bucket = aws_s3_bucket.ses_inbound[0].id

  rule {
    id     = "expire-raw-mail"
    status = "Enabled"

    filter {}

    expiration {
      days = var.inbound_mail_retention_days
    }
  }
}

resource "aws_s3_bucket_policy" "ses_inbound" {
  count  = local.inbound_enabled ? 1 : 0
  bucket = aws_s3_bucket.ses_inbound[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSESPuts"
        Effect = "Allow"
        Principal = {
          Service = "ses.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.ses_inbound[0].arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Secrets Manager — runtime config (addresses + SMTP). Seed is empty; fill in AWS.
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "runtime_config" {
  count       = local.inbound_enabled ? 1 : 0
  name        = "tellerstech/ses-inbound/runtime-config"
  description = "SES inbound runtime config: recipients, gmail_destination, alert_email, smtp"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech SES Inbound Runtime Config"
      "scm:file" = "aws/global/ses/inbound-forwarding.tf"
    },
  )
}

resource "aws_secretsmanager_secret_version" "runtime_config" {
  count     = local.inbound_enabled ? 1 : 0
  secret_id = aws_secretsmanager_secret.runtime_config[0].id

  secret_string = jsonencode({
    gmail_destination = ""
    alert_email       = ""
    recipients        = []
    smtp = {
      host      = ""
      port      = 587
      mailboxes = {}
    }
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# -----------------------------------------------------------------------------
# DynamoDB — rate limits + idempotency
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "inbound_limits" {
  count        = local.inbound_enabled ? 1 : 0
  name         = "tellerstech-ses-inbound-limits"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech SES Inbound Limits"
      "scm:file" = "aws/global/ses/inbound-forwarding.tf"
    },
  )
}

# -----------------------------------------------------------------------------
# SQS + DLQ
# -----------------------------------------------------------------------------

resource "aws_sqs_queue" "inbound_dlq" {
  count                     = local.inbound_enabled ? 1 : 0
  name                      = "tellerstech-ses-inbound-dlq"
  message_retention_seconds = 1209600

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech SES Inbound DLQ"
      "scm:file" = "aws/global/ses/inbound-forwarding.tf"
    },
  )
}

resource "aws_sqs_queue" "inbound" {
  count                      = local.inbound_enabled ? 1 : 0
  name                       = "tellerstech-ses-inbound"
  visibility_timeout_seconds = 120
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 10

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.inbound_dlq[0].arn
    maxReceiveCount     = 3
  })

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech SES Inbound Queue"
      "scm:file" = "aws/global/ses/inbound-forwarding.tf"
    },
  )
}

resource "aws_sqs_queue_policy" "inbound" {
  count     = local.inbound_enabled ? 1 : 0
  queue_url = aws_sqs_queue.inbound[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3Send"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.inbound[0].arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_s3_bucket.ses_inbound[0].arn
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Gate Lambda (sync)
# -----------------------------------------------------------------------------

data "archive_file" "gate_mail" {
  count       = local.inbound_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/gate_mail.py"
  output_path = "${path.module}/lambda/gate_mail.zip"
}

resource "aws_iam_role" "gate_mail" {
  count = local.inbound_enabled ? 1 : 0
  name  = "tellerstech-ses-inbound-gate"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech SES Inbound Gate"
      "scm:file" = "aws/global/ses/inbound-forwarding.tf"
    },
  )
}

resource "aws_iam_role_policy" "gate_mail" {
  count = local.inbound_enabled ? 1 : 0
  name  = "tellerstech-ses-inbound-gate"
  role  = aws_iam_role.gate_mail[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Sid      = "ReadRuntimeConfig"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.runtime_config[0].arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "gate_mail" {
  count             = local.inbound_enabled ? 1 : 0
  name              = "/aws/lambda/tellerstech-ses-inbound-gate"
  retention_in_days = 30

  tags = merge(
    var.core_tags,
    { "scm:file" = "aws/global/ses/inbound-forwarding.tf" },
  )
}

resource "aws_lambda_function" "gate_mail" {
  count = local.inbound_enabled ? 1 : 0

  function_name = "tellerstech-ses-inbound-gate"
  role          = aws_iam_role.gate_mail[0].arn
  handler       = "gate_mail.handler"
  runtime       = "python3.12"
  timeout       = 10
  memory_size   = 128

  filename         = data.archive_file.gate_mail[0].output_path
  source_code_hash = data.archive_file.gate_mail[0].output_base64sha256

  environment {
    variables = {
      RUNTIME_CONFIG_SECRET_ARN = aws_secretsmanager_secret.runtime_config[0].arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.gate_mail]

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech SES Inbound Gate"
      "scm:file" = "aws/global/ses/inbound-forwarding.tf"
    },
  )
}

resource "aws_lambda_permission" "gate_ses" {
  count          = local.inbound_enabled ? 1 : 0
  statement_id   = "AllowSESInvokeGate"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.gate_mail[0].function_name
  principal      = "ses.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}

# -----------------------------------------------------------------------------
# Worker Lambda (async via SQS)
# -----------------------------------------------------------------------------

data "archive_file" "forward_mail" {
  count       = local.inbound_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/forward_mail.py"
  output_path = "${path.module}/lambda/forward_mail.zip"
}

resource "aws_iam_role" "forward_mail" {
  count = local.inbound_enabled ? 1 : 0
  name  = "tellerstech-ses-inbound-forward"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech SES Inbound Forward"
      "scm:file" = "aws/global/ses/inbound-forwarding.tf"
    },
  )
}

resource "aws_iam_role_policy" "forward_mail" {
  count = local.inbound_enabled ? 1 : 0
  name  = "tellerstech-ses-inbound-forward"
  role  = aws_iam_role.forward_mail[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Sid    = "S3Mail"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:HeadObject"
        ]
        Resource = "${aws_s3_bucket.ses_inbound[0].arn}/*"
      },
      {
        Sid      = "SendAsDomain"
        Effect   = "Allow"
        Action   = ["ses:SendRawEmail", "ses:SendEmail"]
        Resource = "*"
      },
      {
        Sid      = "ReadRuntimeConfig"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.runtime_config[0].arn
      },
      {
        Sid    = "DynamoLimits"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:GetItem",
          "dynamodb:DeleteItem"
        ]
        Resource = aws_dynamodb_table.inbound_limits[0].arn
      },
      {
        Sid    = "SQSConsume"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = aws_sqs_queue.inbound[0].arn
      },
      {
        Sid      = "Metrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "TellersTech/SESInbound"
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "forward_mail" {
  count             = local.inbound_enabled ? 1 : 0
  name              = "/aws/lambda/tellerstech-ses-inbound-forward"
  retention_in_days = 30

  tags = merge(
    var.core_tags,
    { "scm:file" = "aws/global/ses/inbound-forwarding.tf" },
  )
}

resource "aws_lambda_function" "forward_mail" {
  count = local.inbound_enabled ? 1 : 0

  function_name                  = "tellerstech-ses-inbound-forward"
  role                           = aws_iam_role.forward_mail[0].arn
  handler                        = "forward_mail.handler"
  runtime                        = "python3.12"
  timeout                        = 60
  memory_size                    = 256
  reserved_concurrent_executions = var.inbound_worker_reserved_concurrency

  filename         = data.archive_file.forward_mail[0].output_path
  source_code_hash = data.archive_file.forward_mail[0].output_base64sha256

  environment {
    variables = {
      RUNTIME_CONFIG_SECRET_ARN = aws_secretsmanager_secret.runtime_config[0].arn
      INBOUND_PREFIX            = local.inbound_prefix
      QUARANTINE_PREFIX         = local.quarantine_prefix
      LIMITS_TABLE_NAME         = aws_dynamodb_table.inbound_limits[0].name
      INBOUND_BUCKET            = aws_s3_bucket.ses_inbound[0].id
      MAX_MESSAGE_BYTES         = tostring(var.inbound_max_message_bytes)
      RATE_LIMIT_PER_RECIPIENT  = tostring(var.inbound_rate_limit_per_recipient)
      RATE_LIMIT_GLOBAL         = tostring(var.inbound_rate_limit_global)
      METRIC_NAMESPACE          = "TellersTech/SESInbound"
    }
  }

  depends_on = [aws_cloudwatch_log_group.forward_mail]

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech SES Inbound Forward"
      "scm:file" = "aws/global/ses/inbound-forwarding.tf"
    },
  )
}

resource "aws_lambda_event_source_mapping" "inbound_sqs" {
  count            = local.inbound_enabled ? 1 : 0
  event_source_arn = aws_sqs_queue.inbound[0].arn
  function_name    = aws_lambda_function.forward_mail[0].arn
  batch_size       = 1
  enabled          = true
}

resource "aws_s3_bucket_notification" "ses_inbound" {
  count  = local.inbound_enabled ? 1 : 0
  bucket = aws_s3_bucket.ses_inbound[0].id

  queue {
    queue_arn     = aws_sqs_queue.inbound[0].arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = local.inbound_prefix
  }

  depends_on = [aws_sqs_queue_policy.inbound]
}

# -----------------------------------------------------------------------------
# SES receipt rules
# -----------------------------------------------------------------------------

resource "aws_ses_receipt_rule_set" "inbound" {
  count         = local.inbound_enabled ? 1 : 0
  rule_set_name = "tellerstech-inbound"
}

resource "aws_ses_active_receipt_rule_set" "inbound" {
  count         = local.inbound_enabled ? 1 : 0
  rule_set_name = aws_ses_receipt_rule_set.inbound[0].rule_set_name
}

resource "aws_ses_receipt_rule" "forward" {
  for_each = local.inbound_enabled ? local.recipient_rule_names : {}

  name          = each.value
  rule_set_name = aws_ses_receipt_rule_set.inbound[0].rule_set_name
  recipients    = [each.key]
  enabled       = true
  scan_enabled  = true
  tls_policy    = var.inbound_tls_policy

  # Chain rules in sorted address order so catch-all can follow the last one.
  after = (
    index(local.sorted_recipients, each.key) == 0
    ? null
    : local.recipient_rule_names[local.sorted_recipients[index(local.sorted_recipients, each.key) - 1]]
  )

  lambda_action {
    function_arn    = aws_lambda_function.gate_mail[0].arn
    invocation_type = "RequestResponse"
    position        = 1
  }

  s3_action {
    bucket_name       = aws_s3_bucket.ses_inbound[0].id
    object_key_prefix = "${local.inbound_prefix}${each.key}/"
    position          = 2
  }

  stop_action {
    scope    = "RuleSet"
    position = 3
  }

  depends_on = [
    aws_s3_bucket_policy.ses_inbound,
    aws_lambda_permission.gate_ses,
  ]
}

resource "aws_ses_receipt_rule" "catch_all_bounce" {
  count = local.inbound_enabled ? 1 : 0

  name          = "catch-all-bounce"
  rule_set_name = aws_ses_receipt_rule_set.inbound[0].rule_set_name
  enabled       = true
  scan_enabled  = true
  tls_policy    = var.inbound_tls_policy

  # No recipients list => matches remaining recipients on verified identities.
  after = length(local.sorted_recipients) > 0 ? local.recipient_rule_names[local.sorted_recipients[length(local.sorted_recipients) - 1]] : null

  bounce_action {
    message         = "Mailbox not available"
    sender          = "mailer-daemon@${var.ses_identity}"
    smtp_reply_code = "550"
    status_code     = "5.1.1"
    position        = 1
  }

  stop_action {
    scope    = "RuleSet"
    position = 2
  }

  depends_on = [aws_ses_receipt_rule.forward]
}

# -----------------------------------------------------------------------------
# Alarms
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "inbound_alerts" {
  count = local.inbound_enabled ? 1 : 0
  name  = "tellerstech-ses-inbound-alerts"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech SES Inbound Alerts"
      "scm:file" = "aws/global/ses/inbound-forwarding.tf"
    },
  )
}

resource "aws_sns_topic_subscription" "inbound_alerts_email" {
  count     = local.inbound_enabled && var.inbound_alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.inbound_alerts[0].arn
  protocol  = "email"
  endpoint  = var.inbound_alert_email
}

resource "aws_cloudwatch_metric_alarm" "flood_suppressed" {
  count               = local.inbound_enabled ? 1 : 0
  alarm_name          = "tellerstech-ses-inbound-flood"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "FloodSuppressed"
  namespace           = "TellersTech/SESInbound"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_description   = "SES inbound flood rate limit suppressed one or more messages"
  alarm_actions       = [aws_sns_topic.inbound_alerts[0].arn]
  ok_actions          = [aws_sns_topic.inbound_alerts[0].arn]

  tags = merge(
    var.core_tags,
    { "scm:file" = "aws/global/ses/inbound-forwarding.tf" },
  )
}

resource "aws_cloudwatch_metric_alarm" "inbound_dlq" {
  count               = local.inbound_enabled ? 1 : 0
  alarm_name          = "tellerstech-ses-inbound-dlq"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_description   = "SES inbound worker DLQ has messages"
  alarm_actions       = [aws_sns_topic.inbound_alerts[0].arn]
  ok_actions          = [aws_sns_topic.inbound_alerts[0].arn]

  dimensions = {
    QueueName = aws_sqs_queue.inbound_dlq[0].name
  }

  tags = merge(
    var.core_tags,
    { "scm:file" = "aws/global/ses/inbound-forwarding.tf" },
  )
}

resource "aws_cloudwatch_metric_alarm" "worker_errors" {
  count               = local.inbound_enabled ? 1 : 0
  alarm_name          = "tellerstech-ses-inbound-worker-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_description   = "SES inbound worker Lambda errors"
  alarm_actions       = [aws_sns_topic.inbound_alerts[0].arn]
  ok_actions          = [aws_sns_topic.inbound_alerts[0].arn]

  dimensions = {
    FunctionName = aws_lambda_function.forward_mail[0].function_name
  }

  tags = merge(
    var.core_tags,
    { "scm:file" = "aws/global/ses/inbound-forwarding.tf" },
  )
}

resource "aws_cloudwatch_metric_alarm" "gate_errors" {
  count               = local.inbound_enabled ? 1 : 0
  alarm_name          = "tellerstech-ses-inbound-gate-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_description   = "SES inbound gate Lambda errors"
  alarm_actions       = [aws_sns_topic.inbound_alerts[0].arn]
  ok_actions          = [aws_sns_topic.inbound_alerts[0].arn]

  dimensions = {
    FunctionName = aws_lambda_function.gate_mail[0].function_name
  }

  tags = merge(
    var.core_tags,
    { "scm:file" = "aws/global/ses/inbound-forwarding.tf" },
  )
}
