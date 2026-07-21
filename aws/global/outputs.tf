output "instance_profile-WBAT_Main_Server" {
  value = module.iam.instance_profile-WBAT_Main_Server
}

output "instance_profile_name-WBAT_Main_Server" {
  value = module.iam.instance_profile_name-WBAT_Main_Server
}

# CloudFront outputs
output "cloudfront_distribution_id" {
  value       = module.cloudfront.distribution_id
  description = "CloudFront distribution ID for www.tellerstech.com"
}

output "cloudfront_distribution_domain_name" {
  value       = module.cloudfront.distribution_domain_name
  description = "CloudFront domain name - CNAME www.tellerstech.com to this in BIND"
}

# ACM outputs
output "acm_validation_records" {
  value       = module.acm.www_tellerstech_validation_records
  description = "Add these CNAME records to BIND for certificate validation (keep permanently for auto-renewal)"
}

# Origin info
output "origin_fqdn" {
  value       = "origin.tellerstech.com"
  description = "Origin FQDN for CloudFront (managed in BIND)"
}

# S3 briefs backup (On Call Brief pipeline)
output "briefs_bucket_id" {
  value       = aws_s3_bucket.briefs.id
  description = "S3 bucket for briefs backup; set BRIEFS_S3_URI=s3://<this_value>/ on the server."
}

output "briefs_bucket_arn" {
  value       = aws_s3_bucket.briefs.arn
  description = "ARN of the briefs backup bucket (for IAM)."
}

# S3 DirectAdmin backups
output "directadmin_backups_bucket_id" {
  value       = aws_s3_bucket.directadmin_backups.id
  description = "S3 bucket for DirectAdmin Enhanced Backups; configure this bucket name in DA."
}

output "directadmin_backup_iam_user" {
  value       = aws_iam_user.directadmin_backup.name
  description = "IAM user DirectAdmin uses for S3 backups; create an access key for it and paste into DA."
}

# SES inbound → Gmail / Roundcube
output "ses_inbound_mx_records" {
  value       = module.ses.ses_inbound_mx_records
  description = "MX records for SES inbound cutover (set in DirectAdmin DNS)"
}

output "ses_inbound_cutover_checklist" {
  value       = module.ses.inbound_cutover_checklist
  description = "Post-apply steps for SES inbound (addresses live in TFC + Secrets Manager)"
}

output "ses_inbound_runtime_config_secret_name" {
  value       = module.ses.inbound_runtime_config_secret_name
  description = "Secrets Manager secret for inbound runtime config"
}

output "ses_inbound_alerts_topic_arn" {
  value       = module.ses.inbound_alerts_topic_arn
  description = "SNS topic for inbound flood/error alarms"
}
