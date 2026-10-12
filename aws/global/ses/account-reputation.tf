# SES account reputation: suppression + alarms on the numbers AWS enforces.
#
# Reputation attaches to the SES *account*, not to an identity or an app, and
# this account has more than one sender: the OCB/SIW newsletters, the DirectAdmin
# → Gmail pipe (scripts/directadmin/ses_gmail_forward.py), Gmail "Send mail as"
# over SES SMTP, and whatever else holds ses:SendRawEmail. The site's own
# deliverability guard only sees the newsletter ledger, so on 2026-10-12 it
# reported a 0.69% bounce rate over 727 sends while SES itself was holding the
# account at 4.07% over ~2,400 — under a point from the 5% review line, with
# no alarm anywhere. These alarms watch the figure SES actually judges.
#
# Thresholds: https://docs.aws.amazon.com/ses/latest/dg/faqs-enforcement.html
#   under review at 5% bounce / 0.1% complaint; may pause at 10% / 0.5%.

# Account-level suppression list. SES stops sending to an address once it has
# hard-bounced or complained, for every identity and every sender in the
# account, so one bad address cannot be bounced against the account daily.
#
# BOUNCE is deliberately not in the default yet. The account has been running
# with suppression off, so the addresses that would be suppressed first are the
# ones bouncing today, and those are not yet attributed (see
# feedback-attribution.tf). If one of them is the DA pipe's Gmail destination —
# Gmail refusing forwarded spam counts as a bounce — enabling BOUNCE would stop
# all forwarded mail silently (the pipe exits 0 by design and only logs). Add
# "BOUNCE" once the attribution queue shows who is bouncing.
resource "aws_sesv2_account_suppression_attributes" "account" {
  suppressed_reasons = var.account_suppressed_reasons
}

resource "aws_sns_topic" "ses_reputation_alerts" {
  name = "ses-reputation-alerts"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "SES Account Reputation Alerts"
      "scm:file" = "aws/global/ses/account-reputation.tf"
    },
  )
}

# After apply, confirm the subscription from the inbox.
resource "aws_sns_topic_subscription" "ses_reputation_alerts_email" {
  count     = var.reputation_alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.ses_reputation_alerts.arn
  protocol  = "email"
  endpoint  = var.reputation_alert_email
}

# Reputation.* are account-wide rates (0–1) that SES publishes on its own
# rolling, representative-volume window; Maximum over an hour is the value SES
# held. treat_missing_data = notBreaching because SES skips datapoints when
# there was too little volume to compute a rate.
resource "aws_cloudwatch_metric_alarm" "ses_bounce_rate" {
  alarm_name          = "ses-account-bounce-rate"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Reputation.BounceRate"
  namespace           = "AWS/SES"
  period              = 3600
  statistic           = "Maximum"
  threshold           = var.bounce_rate_alarm_threshold
  treat_missing_data  = "notBreaching"
  alarm_description   = "SES account bounce rate is at or above ${format("%.3g", var.bounce_rate_alarm_threshold * 100)}%. AWS reviews the account at 5% and may pause sending at 10%. This counts every sender in the account, not only the newsletters."
  alarm_actions       = [aws_sns_topic.ses_reputation_alerts.arn]
  ok_actions          = [aws_sns_topic.ses_reputation_alerts.arn]

  tags = merge(
    var.core_tags,
    {
      "Name"     = "SES Bounce Rate Alarm"
      "scm:file" = "aws/global/ses/account-reputation.tf"
    },
  )
}

resource "aws_cloudwatch_metric_alarm" "ses_complaint_rate" {
  alarm_name          = "ses-account-complaint-rate"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Reputation.ComplaintRate"
  namespace           = "AWS/SES"
  period              = 3600
  statistic           = "Maximum"
  threshold           = var.complaint_rate_alarm_threshold
  treat_missing_data  = "notBreaching"
  alarm_description   = "SES account complaint rate is at or above ${format("%.3g", var.complaint_rate_alarm_threshold * 100)}%. AWS reviews the account at 0.1% and may pause sending at 0.5%."
  alarm_actions       = [aws_sns_topic.ses_reputation_alerts.arn]
  ok_actions          = [aws_sns_topic.ses_reputation_alerts.arn]

  tags = merge(
    var.core_tags,
    {
      "Name"     = "SES Complaint Rate Alarm"
      "scm:file" = "aws/global/ses/account-reputation.tf"
    },
  )
}
