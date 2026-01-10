# CloudWatch Billing Alarms for Cost Monitoring
# These alarms notify when AWS costs exceed thresholds

# SNS Topic for billing alerts
resource "aws_sns_topic" "billing_alerts" {
  name = "billing-alerts"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "Billing Alerts"
      "scm:file" = "aws/global/cloudwatch/billing-alarms.tf"
    },
  )
}

# Email subscription for billing alerts
# Note: After apply, you must confirm the subscription via email
resource "aws_sns_topic_subscription" "billing_alerts_email" {
  count     = var.billing_alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.billing_alerts.arn
  protocol  = "email"
  endpoint  = var.billing_alert_email
}

# Billing alarm - Alert when monthly charges exceed threshold
resource "aws_cloudwatch_metric_alarm" "billing_alarm_warning" {
  alarm_name          = "billing-warning-${var.billing_threshold_warning}usd"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600 # 6 hours
  statistic           = "Maximum"
  threshold           = var.billing_threshold_warning
  alarm_description   = "Warning: AWS charges have exceeded $${var.billing_threshold_warning}"
  alarm_actions       = [aws_sns_topic.billing_alerts.arn]
  ok_actions          = [aws_sns_topic.billing_alerts.arn]

  dimensions = {
    Currency = "USD"
  }

  tags = merge(
    var.core_tags,
    {
      "Name"     = "Billing Warning Alarm"
      "scm:file" = "aws/global/cloudwatch/billing-alarms.tf"
    },
  )
}

# Billing alarm - Critical alert at higher threshold
resource "aws_cloudwatch_metric_alarm" "billing_alarm_critical" {
  alarm_name          = "billing-critical-${var.billing_threshold_critical}usd"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600 # 6 hours
  statistic           = "Maximum"
  threshold           = var.billing_threshold_critical
  alarm_description   = "CRITICAL: AWS charges have exceeded $${var.billing_threshold_critical}"
  alarm_actions       = [aws_sns_topic.billing_alerts.arn]

  dimensions = {
    Currency = "USD"
  }

  tags = merge(
    var.core_tags,
    {
      "Name"     = "Billing Critical Alarm"
      "scm:file" = "aws/global/cloudwatch/billing-alarms.tf"
    },
  )
}
