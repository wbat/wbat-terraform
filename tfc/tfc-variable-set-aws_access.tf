resource "tfe_variable_set" "aws_access" {
  name         = "AWS Access"
  description  = "Variables related to AWS access"
  organization = tfe_organization.wbat.id
}

# AWS Access Key ID (TerraformCloud User)
resource "tfe_variable" "aws_access-aws_access_key_id" {
  key             = "AWS_ACCESS_KEY_ID"
  value           = ""
  category        = "env"
  description     = "AWS Access Key ID - TerraformCloud User"
  sensitive       = true
  variable_set_id = tfe_variable_set.aws_access.id

  lifecycle {
    ignore_changes = [value]
  }
}

# AWS Secret Access Key (TerraformCloud User)
resource "tfe_variable" "aws_access-aws_secret_access_key" {
  key             = "AWS_SECRET_ACCESS_KEY"
  value           = ""
  category        = "env"
  description     = "AWS Secret Access Key - TerraformCloud User"
  sensitive       = true
  variable_set_id = tfe_variable_set.aws_access.id

  lifecycle {
    ignore_changes = [value]
  }
}

resource "tfe_workspace_variable_set" "aws" {
  variable_set_id = tfe_variable_set.aws_access.id
  workspace_id    = tfe_workspace.aws.id
}
