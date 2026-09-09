output "host_health_alerts_topic_arn" {
  value       = aws_sns_topic.host_health_alerts.arn
  description = "SNS topic for EC2 status-check (and later disk/memory) alarms."
}
