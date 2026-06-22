output "email_forwarding_topic_arn" {
  description = "ARN of the email forwarding SNS topic"
  value       = aws_sns_topic.email_forwarding.arn
}

output "email_forwarding_topic_name" {
  description = "Name of the email forwarding SNS topic"
  value       = aws_sns_topic.email_forwarding.name
}

output "ses_feedback_topic_arn" {
  description = "ARN of the SES bounce/complaint feedback SNS topic"
  value       = aws_sns_topic.ses_feedback.arn
}

output "ses_feedback_topic_name" {
  description = "Name of the SES bounce/complaint feedback SNS topic"
  value       = aws_sns_topic.ses_feedback.name
}
