# SNS Topic for SES Email Forwarding
# Used by SES to publish notifications when emails are received

resource "aws_sns_topic" "email_forwarding" {
  name = "tellertech-email-forwarding"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech Email Forwarding"
      "scm:file" = "aws/global/ses/email-forwarding.tf"
    },
  )
}

# SNS Topic Policy - allows SES to publish to this topic
resource "aws_sns_topic_policy" "email_forwarding" {
  arn = aws_sns_topic.email_forwarding.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSESPublish"
        Effect = "Allow"
        Principal = {
          Service = "ses.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.email_forwarding.arn
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

data "aws_caller_identity" "current" {}

# Email subscription for forwarding notifications
# Note: After apply, you must confirm the subscription via email
resource "aws_sns_topic_subscription" "email_forwarding" {
  count     = var.tellerstech_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.email_forwarding.arn
  protocol  = "email"
  endpoint  = var.tellerstech_email
}
