resource "tfe_workspace" "aws" {
  name         = "wbat-terraform-aws"
  description  = "WBAT's AWS Workspace"
  organization = tfe_organization.wbat.id

  auto_apply            = false
  execution_mode        = "remote"
  queue_all_runs        = false
  global_remote_state   = true
  terraform_version     = "1.7.2"
  working_directory     = "aws"
  file_triggers_enabled = true
  ssh_key_id            = data.tfe_ssh_key.WBAT.id

  vcs_repo {
    identifier         = "wbat/wbat-terraform"
    ingress_submodules = "true"
    branch             = "main"
    oauth_token_id     = "ot-MNgANjF1qnpfxdry"
  }

  structured_run_output_enabled = true
}
