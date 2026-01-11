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
######################################################
variable "personal_email" {
  description = "Personal email address for billing and admin notifications (brianateller@gmail.com)"
  default     = "email@address.com"
}

variable "tellerstech_email" {
  description = "TellersTech email address for business notifications (tellerstech@gmail.com)"
  default     = "email@address.com"
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
