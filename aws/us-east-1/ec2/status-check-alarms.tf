# EC2 status-check alarms.
#
# StatusCheckFailed_Instance is free, needs no agent, and is the metric that sat
# at 1 for ~4.5 hours during the 2026-09-06 primary outage with nothing watching
# it (see aws/docs/2026-09-06-primary-outage.md). StatusCheckFailed_System is
# the AWS-side counterpart (power/network/host). Both fire after two one-minute
# periods at >= 1 so a single missed sample does not page.

locals {
  status_check_alarms = {
    primary-instance = {
      instance_id = aws_instance.primary.id
      metric      = "StatusCheckFailed_Instance"
      label       = "primary"
    }
    primary-system = {
      instance_id = aws_instance.primary.id
      metric      = "StatusCheckFailed_System"
      label       = "primary"
    }
    secondary-instance = {
      instance_id = aws_instance.secondary.id
      metric      = "StatusCheckFailed_Instance"
      label       = "secondary"
    }
    secondary-system = {
      instance_id = aws_instance.secondary.id
      metric      = "StatusCheckFailed_System"
      label       = "secondary"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "status_check" {
  for_each = local.status_check_alarms

  alarm_name          = "ec2-${each.key}-status-check-failed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = each.value.metric
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_description = "EC2 ${each.value.metric} on the ${each.value.label} server (${each.value.instance_id}). This is the free status-check metric that went unalarmed during the 2026-09-06 primary outage."

  alarm_actions = [var.host_health_alerts_topic_arn]
  ok_actions    = [var.host_health_alerts_topic_arn]

  dimensions = {
    InstanceId = each.value.instance_id
  }

  tags = merge(
    var.core_tags,
    {
      "Name"     = "EC2 ${each.value.label} ${each.value.metric}"
      "scm:file" = "aws/us-east-1/ec2/status-check-alarms.tf"
    },
  )
}
