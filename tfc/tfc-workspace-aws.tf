resource "tfe_workspace" "aws" {
  name         = "wbat-terraform-aws"
  description  = "WBAT's AWS Workspace"
  organization = tfe_organization.wbat.id

  auto_apply     = true
  queue_all_runs = false

  terraform_version     = "1.14.3"
  working_directory     = "aws"
  file_triggers_enabled = true
  trigger_patterns      = ["/aws/**"]
  ssh_key_id            = data.tfe_ssh_key.WBAT.id

  vcs_repo {
    identifier                 = "wbat/wbat-terraform"
    github_app_installation_id = "ghain-VDZVR9k8AKtDbiYa"
  }

  structured_run_output_enabled = true
}

resource "tfe_workspace_settings" "aws" {
  workspace_id        = tfe_workspace.aws.id
  execution_mode      = "remote"
  global_remote_state = true
}

resource "tfe_variable" "aws_cloudfront_origin_secret" {
  count        = var.cloudfront_origin_secret != "" ? 1 : 0
  key          = "cloudfront_origin_secret"
  value        = var.cloudfront_origin_secret
  category     = "terraform"
  workspace_id = tfe_workspace.aws.id
  sensitive    = true
  description  = "Secret header value for CloudFront origin verification"
}
