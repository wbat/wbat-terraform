output "email_forwarding_topic_arn" {
  description = "ARN of the email forwarding SNS topic"
  value       = aws_sns_topic.email_forwarding.arn
}

output "email_forwarding_topic_name" {
  description = "Name of the email forwarding SNS topic"
  value       = aws_sns_topic.email_forwarding.name
}
