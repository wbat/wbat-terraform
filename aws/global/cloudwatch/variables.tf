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

variable "host_health_alert_email" {
  description = "Email for EC2 status-check / host-health alarms (leave empty to skip subscription)"
  type        = string
  default     = ""
}
