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

variable "billing_alert_email" {
  description = "Email address to receive billing alerts (leave empty to skip email subscription)"
  type        = string
  default     = ""
}

variable "billing_threshold_warning" {
  description = "Warning threshold for monthly AWS charges (USD)"
  type        = number
  default     = 75
}

variable "billing_threshold_critical" {
  description = "Critical threshold for monthly AWS charges (USD)"
  type        = number
  default     = 100
}
