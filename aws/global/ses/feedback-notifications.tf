# SES Bounce/Complaint Feedback Loop
#
# Wires SES bounce + complaint feedback for the tellerstech.com sending
# identity to an SNS topic, then delivers those notifications to the site's
# webhook so it can suppress bad addresses and surface counts in the OCB/SIW
# admin dashboards.
#
# Flow:
#   SES (Bounce|Complaint) -> SNS topic -> HTTPS subscription -> WP webhook
#
# The webhook (tt_sub_handle_sns) verifies the SNS signature, auto-confirms
# the subscription handshake, and applies suppression globally by email, so a
# single subscription covers every list (OCB + SIW).
#
# Note: the SES domain identity (tellerstech.com) is provisioned outside this
# repo, so it is referenced by name via var.ses_identity rather than as a
# managed resource. data.aws_caller_identity.current is declared in
# email-forwarding.tf and reused here.

resource "aws_sns_topic" "ses_feedback" {
  name = "tellerstech-ses-notifications"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech SES Bounce/Complaint Notifications"
      "scm:file" = "aws/global/ses/feedback-notifications.tf"
    },
  )
}

# Allow SES (from this account only) to publish feedback to the topic.
resource "aws_sns_topic_policy" "ses_feedback" {
  arn = aws_sns_topic.ses_feedback.arn

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
        Resource = aws_sns_topic.ses_feedback.arn
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# Deliver notifications to the site webhook. The endpoint auto-confirms the
# SNS subscription handshake, so this becomes "Confirmed" without manual steps.
resource "aws_sns_topic_subscription" "ses_feedback_webhook" {
  topic_arn              = aws_sns_topic.ses_feedback.arn
  protocol               = "https"
  endpoint               = var.ses_feedback_endpoint
  endpoint_auto_confirms = true
  raw_message_delivery   = false
}

# Point the SES identity's Complaint + Bounce feedback at the SNS topic.
# include_original_headers lets the webhook attribute events more precisely.
resource "aws_ses_identity_notification_topic" "complaint" {
  identity                 = var.ses_identity
  notification_type        = "Complaint"
  topic_arn                = aws_sns_topic.ses_feedback.arn
  include_original_headers = true
}

resource "aws_ses_identity_notification_topic" "bounce" {
  identity                 = var.ses_identity
  notification_type        = "Bounce"
  topic_arn                = aws_sns_topic.ses_feedback.arn
  include_original_headers = true
}
