variable "core_tags" {}

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
