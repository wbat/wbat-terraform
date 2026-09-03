# Variable Sets for shared variables across workspaces

resource "tfe_variable_set" "cloudfront" {
  name         = "CloudFront"
  description  = "Variables for CloudFront configuration"
  organization = tfe_organization.wbat.id
}

resource "tfe_variable" "cloudfront_origin_secret" {
  key             = "cloudfront_origin_secret"
  value           = var.cloudfront_origin_secret
  category        = "terraform"
  variable_set_id = tfe_variable_set.cloudfront.id
  sensitive       = true
  description     = "Secret header value for CloudFront origin verification"

  # Same bootstrap pattern as the email and AWS access variables: the real value is
  # set on the variable set in TFC, not from this workspace. Without this, a
  # wbat-terraform-tfc apply that does not have cloudfront_origin_secret set would
  # push the "" default into the set feeding wbat-terraform-aws. CloudFront would
  # then send an empty X-CloudFront-Secret, the nginx origin gate would stop
  # matching, and the origin would 403 every request -- which CloudFront does not
  # remap, so viewers would see it.
  lifecycle {
    ignore_changes = [value]
  }
}

# Attach CloudFront variable set to AWS workspace
resource "tfe_workspace_variable_set" "aws_cloudfront" {
  workspace_id    = tfe_workspace.aws.id
  variable_set_id = tfe_variable_set.cloudfront.id
}
