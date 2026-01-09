variable "core_tags" {}

variable "origin_fqdn" {
  description = "FQDN of the origin server"
  type        = string
  default     = "origin.tellerstech.com"
}

variable "acm_certificate_arn" {
  description = "ARN of the ACM certificate for www.tellerstech.com"
  type        = string
}

variable "cloudfront_origin_secret" {
  description = "Secret header value to verify requests come from CloudFront"
  type        = string
  sensitive   = true
  default     = ""
}

variable "enable_legacy_cdn" {
  description = "Enable the legacy W3TC CDN distribution (cdn.aws.tellerstech.com). Set to false to disable/remove."
  type        = bool
  default     = true
}

variable "enable_waf" {
  description = "Enable AWS WAF for CloudFront (adds ~$5-10/month). Provides rate limiting, bot protection, and OWASP rules."
  type        = bool
  default     = false
}
