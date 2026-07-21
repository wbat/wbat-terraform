variable "core_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}

variable "tellerstech_email" {
  description = "Legacy SNS email endpoint for the old forwarding-notification topic (TFC sensitive; leave empty to skip)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "ses_identity" {
  description = "SES sending identity (domain) that bounce/complaint feedback is configured for"
  type        = string
  default     = "tellerstech.com"
}

variable "ses_feedback_endpoint" {
  description = "HTTPS webhook that receives SES bounce/complaint SNS notifications"
  type        = string
  default     = "https://www.tellerstech.com/wp-json/tellerstech/v1/ocb-ses-notification"
}
