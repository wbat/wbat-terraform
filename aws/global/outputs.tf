output "instance_profile-WBAT_Main_Server" {
  value = module.iam.instance_profile-WBAT_Main_Server
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

# Route53 outputs
output "origin_fqdn" {
  value       = module.route53.origin_fqdn
  description = "Origin FQDN for CloudFront (origin.aws.tellerstech.com)"
}
