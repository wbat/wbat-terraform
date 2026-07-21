# Variables for the various provider credentials are configured here.
# Rather than have a credentials.auto.tfvars.dist file this file can be used as the .dist
#
# There are multiple methods for setting these variables.  Please see https://www.terraform.io/intro/getting-started/variables.html
# and it is up to the user to determine which method to use.
#
# If you choose to use the file method, then the below are instructions on how to create a file, which is in .gitignore so it will not be included in any commits.
#
# * Copy this file to credentials.auto.tfvars
# * Change each line so that it follows a `key = "value"` format instead of `variable "aws_access_key" {}`
#

######################################################
# Email Addresses
#
# Prefer Terraform Cloud sensitive variables / variable sets for real values.
# credentials.auto.tfvars is gitignored — never commit real addresses.
# For SES inbound, also set:
#   enable_inbound_forwarding = true
#   inbound_recipients        = ["recipient@example.com"]  # sensitive HCL
#   inbound_alert_email       = "alerts@example.com"       # optional, sensitive
# And populate Secrets Manager tellerstech/ses-inbound/runtime-config after apply.
#
######################################################
variable "personal_email" {
  description = "Personal email for billing/admin notifications (TFC sensitive preferred)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "tellerstech_email" {
  description = "Business notification email for legacy SES SNS topics (TFC sensitive preferred)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "enable_inbound_forwarding" {
  description = "Provision SES inbound receive + gated Lambda forward to Gmail/Roundcube"
  type        = bool
  default     = false
}

variable "inbound_recipients" {
  description = "Allowlisted addresses for SES receipt rules (TFC sensitive HCL list)"
  type        = list(string)
  sensitive   = true
  default     = []
}

variable "inbound_alert_email" {
  description = "Optional SNS email for inbound flood/error alarms (TFC sensitive)"
  type        = string
  sensitive   = true
  default     = ""
}

######################################################
# CloudFront Origin Secret
#
######################################################
variable "cloudfront_origin_secret" {
  sensitive   = true
  description = "Secret header value for CloudFront origin verification"
  default     = ""
}
