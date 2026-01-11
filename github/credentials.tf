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
# Github
#
# https://help.github.com/articles/creating-a-personal-access-token-for-the-command-line/
#
######################################################
variable "github_oauth_token" {
  sensitive = true
}

######################################################
# Email Address
#
######################################################
variable "personal_email" {
  description = "Personal email address for billing and admin notifications (brianateller@gmail.com)"
  default     = ""
}
