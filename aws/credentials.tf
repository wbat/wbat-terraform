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
#
# TellersTech inbound mail (canonical):
#   MX stays on DirectAdmin. Pipe script + Secrets Manager
#   tellerstech/ses-gmail-forward/runtime-config
#   See scripts/directadmin/ses_gmail_forward.md
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

######################################################
# CloudFront Origin Secret
#
######################################################
variable "cloudfront_origin_secret" {
  sensitive   = true
  description = "Secret header value for CloudFront origin verification"
  default     = ""
}

######################################################
# DirectAdmin panel (2222) ingress allowlist
#
# Keys are labels, values are CIDRs. Set the real value as a Terraform Cloud
# workspace variable — do NOT commit it. This repository is public, and a
# residential address is personal data even though it is not a credential.
#
#   da_panel_allowed_cidrs = { home = "203.0.113.10/32" }
#
# Not marked sensitive: these are for_each keys downstream, and Terraform
# refuses to iterate a sensitive value. Terraform Cloud keeps the value out of
# the repository either way, which is the exposure that matters here.
#
# Empty default is deliberate and safe. With no entries, no ingress rule is
# created and nothing changes — it cannot lock anyone out by omission. See
# aws/docs/host-access-hardening.md for the apply-then-revoke order.
######################################################
variable "da_panel_allowed_cidrs" {
  description = "label => CIDR allowed to reach the DirectAdmin panel on 2222"
  type        = map(string)
  default     = {}
}
