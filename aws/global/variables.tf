variable "core_tags" {}
variable "terraform_cloud_external_id" {}

variable "cloudfront_origin_secret" {
  description = "Secret header value to verify requests come from CloudFront (optional)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "enable_legacy_cdn" {
  description = "Enable the legacy W3TC CDN distribution (cdn.aws.tellerstech.com)"
  type        = bool
  default     = true
}

variable "enable_waf" {
  description = "Enable AWS WAF for CloudFront (adds ~$5-10/month)"
  type        = bool
  default     = false
}
