# Variables for the various provider credentials are configured here.
# Rather than have a credentials.auto.tfvars.dist file this file can be used as the .dist
#
# There are multiple methods for setting these variables.  Please see https://www.terraform.io/intro/getting-started/variables.html
# and it is up to the user to determine which method to use.
#
# If you choose to use the file method, then the below are instructions on how to create a file, which is in .gitignore so it will not be included in any commits.
#
# * Copy this file to credentials.auto.tfvars
# * Change each line so that it follows a `key = "value"` format instead of `variable "tfe_token" {}`
#

######################################################
# TFE
#
# TFE Token is stored in 1password Devop's vault/TFE Prod Api Token
#
######################################################
variable "tfc_token" {
  sensitive = true
}

######################################################
# Email Address
#
######################################################
variable "email_address" {
  sensitive = true
}
