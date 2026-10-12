# Who is bouncing? Bounce/complaint feedback for every non-newsletter identity.
#
# Only tellerstech.com had a bounce/complaint topic (feedback-notifications.tf),
# and that topic feeds the WP webhook, which only understands subscriber rows.
# Every other identity relied on SES "email feedback forwarding", which mails
# the notice to the sending address — so the ~15 bounces a day the account was
# taking from non-newsletter mail were landing in mailboxes nobody reads, with
# no record of which sender or recipient they belonged to.
#
# This fans those notifications into an SQS queue instead of an inbox: one
# message per bounce/complaint, carrying the source identity, the recipient,
# the bounce type and (include_original_headers) the original From/Subject.
# Read it with:
#
#   aws sqs receive-message --queue-url "$(terraform output -raw ses_feedback_attribution_queue_url)" \
#     --max-number-of-messages 10 --visibility-timeout 0
#
# Retention is the SQS maximum (14 days) so a week of traffic is always there to
# read. Nothing consumes the queue; it is a diagnostic ledger, not a pipeline.
# Feedback forwarding stays on, so mail that used to arrive still does.

resource "aws_sns_topic" "ses_feedback_attribution" {
  name = "ses-feedback-attribution"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "SES Feedback Attribution - non-newsletter identities"
      "scm:file" = "aws/global/ses/feedback-attribution.tf"
    },
  )
}

resource "aws_sns_topic_policy" "ses_feedback_attribution" {
  arn = aws_sns_topic.ses_feedback_attribution.arn

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
        Resource = aws_sns_topic.ses_feedback_attribution.arn
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_sqs_queue" "ses_feedback_attribution" {
  name                      = "ses-feedback-attribution"
  message_retention_seconds = 1209600 # 14 days, the SQS maximum
  sqs_managed_sse_enabled   = true

  tags = merge(
    var.core_tags,
    {
      "Name"     = "SES Feedback Attribution"
      "scm:file" = "aws/global/ses/feedback-attribution.tf"
    },
  )
}

resource "aws_sqs_queue_policy" "ses_feedback_attribution" {
  queue_url = aws_sqs_queue.ses_feedback_attribution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowFeedbackTopic"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.ses_feedback_attribution.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_sns_topic.ses_feedback_attribution.arn
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "ses_feedback_attribution_queue" {
  topic_arn            = aws_sns_topic.ses_feedback_attribution.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.ses_feedback_attribution.arn
  raw_message_delivery = true
}

# SES sends as the most specific verified identity, so a message From
# someone@lmgt.com uses the email-address identity when one is verified and the
# lmgt.com domain identity otherwise. Domains are listed in code (they are in
# public DNS anyway); email-address identities go in the HCP Terraform variable
# ses_attribution_extra_identities so no mailbox address lands in this public repo.
locals {
  ses_attribution_identities = setunion(var.ses_attribution_domains, var.ses_attribution_extra_identities)
  ses_attribution_feedback = {
    for pair in setproduct(local.ses_attribution_identities, ["Bounce", "Complaint"]) :
    "${pair[0]}/${pair[1]}" => { identity = pair[0], type = pair[1] }
  }
}

resource "aws_ses_identity_notification_topic" "attribution" {
  for_each = local.ses_attribution_feedback

  identity                 = each.value.identity
  notification_type        = each.value.type
  topic_arn                = aws_sns_topic.ses_feedback_attribution.arn
  include_original_headers = true
}
