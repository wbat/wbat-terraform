output "distribution_id" {
  value       = aws_cloudfront_distribution.tellerstech_website.id
  description = "CloudFront distribution ID for invalidations"
}

output "distribution_domain_name" {
  value       = aws_cloudfront_distribution.tellerstech_website.domain_name
  description = "CloudFront domain name (e.g., d1234abcd.cloudfront.net) - CNAME www to this"
}

output "distribution_arn" {
  value       = aws_cloudfront_distribution.tellerstech_website.arn
  description = "CloudFront distribution ARN"
}
