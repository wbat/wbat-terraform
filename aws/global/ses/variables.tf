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

variable "account_suppressed_reasons" {
  description = "Reasons SES adds an address to the account-level suppression list. Add \"BOUNCE\" once feedback-attribution.tf shows the bouncing recipients are not the DA pipe's Gmail destination."
  type        = list(string)
  default     = ["COMPLAINT"]

  validation {
    condition     = alltrue([for r in var.account_suppressed_reasons : contains(["BOUNCE", "COMPLAINT"], r)])
    error_message = "Each reason must be BOUNCE or COMPLAINT."
  }
}

variable "reputation_alert_email" {
  description = "Email for SES account bounce/complaint-rate alarms (leave empty to skip subscription)"
  type        = string
  default     = ""
}

variable "bounce_rate_alarm_threshold" {
  description = "SES Reputation.BounceRate (0-1) at which to alarm. AWS reviews the account at 0.05."
  type        = number
  default     = 0.03
}

variable "complaint_rate_alarm_threshold" {
  description = "SES Reputation.ComplaintRate (0-1) at which to alarm. AWS reviews the account at 0.001."
  type        = number
  default     = 0.0008
}

variable "ses_attribution_domains" {
  description = "Domain identities whose bounce/complaint feedback goes to the attribution queue. tellerstech.com is excluded: its feedback already goes to the WP webhook."
  type        = set(string)
  default = [
    "briantayler.com",
    "frazzy.com",
    "iotsystems.com",
    "joltster.com",
    "lmgt.com",
    "swiftmailnow.com",
    "wbat.dev",
    "wbat.net",
    "wbat2.dev",
  ]
}

variable "ses_attribution_extra_identities" {
  description = "Verified email-address identities to include in the attribution queue. Set in HCP Terraform, not in git, so no mailbox address is committed to this public repo."
  type        = set(string)
  default     = []
}
