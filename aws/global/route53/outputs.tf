output "origin_fqdn" {
  value       = aws_route53_record.origin.fqdn
  description = "FQDN for CloudFront origin (origin.aws.tellerstech.com)"
}

output "zone_id" {
  value       = data.aws_route53_zone.aws_tellerstech.zone_id
  description = "Zone ID for aws.tellerstech.com"
}
