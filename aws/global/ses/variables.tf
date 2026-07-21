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

variable "enable_inbound_forwarding" {
  description = "Provision SES inbound receive + gated Lambda forward to Gmail / Roundcube"
  type        = bool
  default     = false
}

variable "inbound_recipients" {
  description = "Allowlisted local addresses for SES receipt rules (set in TFC as a sensitive HCL list; never commit values)"
  type        = list(string)
  sensitive   = true
  default     = []

  validation {
    condition     = !var.enable_inbound_forwarding || length(var.inbound_recipients) > 0
    error_message = "When enable_inbound_forwarding is true, set inbound_recipients in the Terraform Cloud variable set (sensitive HCL list)."
  }
}

variable "inbound_alert_email" {
  description = "Optional SNS email subscriber for inbound flood/error alarms (TFC sensitive; leave empty to subscribe manually)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "inbound_mail_retention_days" {
  description = "Days to retain raw inbound / quarantine MIME objects in S3"
  type        = number
  default     = 30
}

variable "inbound_max_message_bytes" {
  description = "Max raw message size the worker will forward (bytes)"
  type        = number
  default     = 10485760 # 10 MiB
}

variable "inbound_rate_limit_per_recipient" {
  description = "Max messages per recipient per hour before flood quarantine"
  type        = number
  default     = 30
}

variable "inbound_rate_limit_global" {
  description = "Max messages across all allowlisted recipients per hour before flood quarantine"
  type        = number
  default     = 100
}

variable "inbound_worker_reserved_concurrency" {
  description = "Reserved concurrency for the inbound worker Lambda (burst control)"
  type        = number
  default     = 2
}

variable "inbound_tls_policy" {
  description = "SES receipt TLS policy: Require or Optional"
  type        = string
  default     = "Require"

  validation {
    condition     = contains(["Require", "Optional"], var.inbound_tls_policy)
    error_message = "inbound_tls_policy must be Require or Optional."
  }
}
