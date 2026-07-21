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

output "inbound_forwarding_enabled" {
  description = "Whether SES inbound + Lambda forwarding is provisioned"
  value       = var.enable_inbound_forwarding
}

output "inbound_gate_lambda_name" {
  description = "Sync SES receipt gate Lambda name"
  value       = try(aws_lambda_function.gate_mail[0].function_name, null)
}

output "inbound_worker_lambda_name" {
  description = "Async inbound worker Lambda name"
  value       = try(aws_lambda_function.forward_mail[0].function_name, null)
}

output "inbound_s3_bucket" {
  description = "S3 bucket storing raw inbound and quarantine MIME"
  value       = try(aws_s3_bucket.ses_inbound[0].id, null)
}

output "inbound_sqs_queue_url" {
  description = "SQS queue URL feeding the inbound worker"
  value       = try(aws_sqs_queue.inbound[0].id, null)
}

output "inbound_dlq_url" {
  description = "Dead-letter queue URL for failed inbound processing"
  value       = try(aws_sqs_queue.inbound_dlq[0].id, null)
}

output "inbound_runtime_config_secret_name" {
  description = "Secrets Manager secret name for runtime config (recipients, gmail_destination, smtp)"
  value       = try(aws_secretsmanager_secret.runtime_config[0].name, null)
}

output "inbound_runtime_config_secret_arn" {
  description = "Secrets Manager secret ARN for runtime config"
  value       = try(aws_secretsmanager_secret.runtime_config[0].arn, null)
}

output "inbound_alerts_topic_arn" {
  description = "SNS topic for inbound flood/error alarms"
  value       = try(aws_sns_topic.inbound_alerts[0].arn, null)
}

output "ses_inbound_mx_records" {
  description = "MX to publish in DirectAdmin DNS for the receiving domain after apply + runtime secret is populated"
  value = var.enable_inbound_forwarding ? [
    {
      priority = 10
      hostname = "inbound-smtp.${data.aws_region.current.name}.amazonaws.com"
    }
  ] : []
}

output "inbound_cutover_checklist" {
  description = "Post-apply steps (no mailbox addresses — those live in TFC + Secrets Manager)"
  value = var.enable_inbound_forwarding ? [
    "1. Set TFC sensitive variable inbound_recipients (HCL list of allowlisted addresses)",
    "2. Optionally set TFC sensitive inbound_alert_email for alarm SNS email confirm",
    "3. Put runtime JSON in Secrets Manager secret tellerstech/ses-inbound/runtime-config (recipients, gmail_destination, alert_email, smtp.host/port/mailboxes)",
    "4. Confirm allowlisted mailboxes exist in DirectAdmin for Roundcube",
    "5. Delete DirectAdmin forwarders that pointed those addresses at Gmail",
    "6. In DirectAdmin DNS for the domain, set MX 10 to inbound-smtp.<region>.amazonaws.com and remove the old MX",
    "7. Send a test from an external account; verify Gmail + Roundcube + gate/worker logs; confirm SNS alarm email if configured",
    "8. Rollback: restore previous MX; set enable_inbound_forwarding=false or deactivate the receipt rule set",
  ] : []
}
