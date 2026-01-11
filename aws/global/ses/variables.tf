variable "core_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}

variable "tellerstech_email" {
  description = "TellersTech email address for forwarding notifications"
  type        = string
  default     = ""
}
