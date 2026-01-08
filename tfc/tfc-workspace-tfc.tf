resource "tfe_workspace" "tfc" {
  name         = "wbat-terraform-tfc"
  description  = "WBAT's Terraform Cloud Workspace"
  organization = tfe_organization.wbat.id

  auto_apply     = false
  queue_all_runs = false

  terraform_version     = "1.14.3"
  working_directory     = "tfc"
  file_triggers_enabled = true
  trigger_patterns      = ["/tfc/**", "/tfc/**/*"]
  ssh_key_id            = data.tfe_ssh_key.WBAT.id

  vcs_repo {
    identifier                 = "wbat/wbat-terraform"
    github_app_installation_id = "ghain-VDZVR9k8AKtDbiYa"
  }

  structured_run_output_enabled = true
}

resource "tfe_workspace_settings" "tfc" {
  workspace_id        = tfe_workspace.tfc.id
  execution_mode      = "remote"
  global_remote_state = true
}
