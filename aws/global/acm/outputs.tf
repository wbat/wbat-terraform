output "www_tellerstech_certificate_arn" {
  value       = aws_acm_certificate.www_tellerstech.arn
  description = "ARN of the ACM certificate for www.tellerstech.com"
}

output "www_tellerstech_validation_records" {
  value       = aws_acm_certificate.www_tellerstech.domain_validation_options
  description = "DNS validation records - add these CNAMEs to BIND and KEEP THEM for auto-renewal"
}
