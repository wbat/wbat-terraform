# SNS topic for host-health alarms (EC2 status checks now; disk/memory once the
# CloudWatch agent is publishing). Kept separate from billing-alerts so a cost
# spike and a dead primary do not share one confirmation email / mute switch.

resource "aws_sns_topic" "host_health_alerts" {
  name = "host-health-alerts"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "Host Health Alerts"
      "scm:file" = "aws/global/cloudwatch/host-health-alerts.tf"
    },
  )
}

# After apply, confirm the subscription from the inbox. Same address as billing
# by default (wired from var.personal_email at the root).
resource "aws_sns_topic_subscription" "host_health_alerts_email" {
  count     = var.host_health_alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.host_health_alerts.arn
  protocol  = "email"
  endpoint  = var.host_health_alert_email
}
