variable "core_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}

variable "tellerstech_email" {
  description = "TellersTech email address for forwarding notifications"
  type        = string
  default     = ""
}

variable "ses_identity" {
  description = "SES sending identity (domain) that bounce/complaint feedback is configured for"
  type        = string
  default     = "tellerstech.com"
}

variable "ses_feedback_endpoint" {
  description = "HTTPS webhook that receives SES bounce/complaint SNS notifications. Suppression is applied globally by email, so one endpoint covers all lists (OCB + SIW)."
  type        = string
  default     = "https://www.tellerstech.com/wp-json/tellerstech/v1/ocb-ses-notification"
}
