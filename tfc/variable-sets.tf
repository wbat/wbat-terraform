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
}

# Attach CloudFront variable set to AWS workspace
resource "tfe_workspace_variable_set" "aws_cloudfront" {
  workspace_id    = tfe_workspace.aws.id
  variable_set_id = tfe_variable_set.cloudfront.id
}
