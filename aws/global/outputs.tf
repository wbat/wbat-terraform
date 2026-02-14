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
