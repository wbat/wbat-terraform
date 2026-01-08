resource "tfe_workspace" "aws" {
  name         = "wbat-terraform-aws"
  description  = "WBAT's AWS Workspace"
  organization = tfe_organization.wbat.id

  auto_apply            = false
  queue_all_runs        = false
  global_remote_state   = true
  terraform_version     = "1.14.3"
  working_directory     = "aws"
  file_triggers_enabled = true
  trigger_patterns      = ["/aws"]
  ssh_key_id            = data.tfe_ssh_key.WBAT.id

  vcs_repo {
    identifier         = "wbat/wbat-terraform"
    ingress_submodules = "true"
    branch             = "main"
    oauth_token_id     = "ot-MNgANjF1qnpfxdry"
  }

  structured_run_output_enabled = true
}

resource "tfe_workspace_settings" "aws" {
  workspace_id   = tfe_workspace.aws.id
  execution_mode = "remote"
}
