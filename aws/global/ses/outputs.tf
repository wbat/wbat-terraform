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
  description = "Only if enable_inbound_forwarding=true (not used when DirectAdmin owns MX)"
  value = var.enable_inbound_forwarding ? [
    {
      priority = 10
      hostname = "inbound-smtp.${data.aws_region.current.name}.amazonaws.com"
    }
  ] : []
}

output "inbound_cutover_checklist" {
  description = "Legacy SES-receive cutover (prefer DA pipe forward; keep enable_inbound_forwarding=false)"
  value = var.enable_inbound_forwarding ? [
    "WARNING: Enabling this moves inbound MX to SES; DirectAdmin will not be primary MX.",
    "Prefer scripts/directadmin/ses_gmail_forward.py with MX left on DirectAdmin instead.",
    "1. Set TFC sensitive variable inbound_recipients (HCL list of allowlisted addresses)",
    "2. Optionally set TFC sensitive inbound_alert_email for alarm SNS email confirm",
    "3. Put runtime JSON in Secrets Manager secret tellerstech/ses-inbound/runtime-config",
    "4. Confirm allowlisted mailboxes exist in DirectAdmin for Roundcube reinject",
    "5. Delete DirectAdmin forwarders that pointed those addresses at Gmail",
    "6. Set MX 10 to inbound-smtp.<region>.amazonaws.com (replaces DA as inbound)",
    "7. Test externally; verify Gmail + Roundcube reinject + Lambda logs",
    "8. Rollback: restore previous MX; set enable_inbound_forwarding=false",
    ] : [
    "enable_inbound_forwarding is false — use DirectAdmin MX + ses_gmail_forward.py (see scripts/directadmin/ses_gmail_forward.md)",
  ]
}

output "da_gmail_forward_secret_name" {
  description = "Secrets Manager secret for DirectAdmin → SES Gmail pipe forward"
  value       = aws_secretsmanager_secret.da_gmail_forward.name
}

output "da_gmail_forward_secret_arn" {
  description = "Secrets Manager ARN for DirectAdmin → SES Gmail pipe forward"
  value       = aws_secretsmanager_secret.da_gmail_forward.arn
}
