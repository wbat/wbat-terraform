locals {

  tfc-workspace_ids = [
    tfe_workspace.aws.id,
    tfe_workspace.github.id,
    tfe_workspace.tfc.id,
  ]

  # Workspaces that receive the email variable set
  # Excludes TFC because it manages the variable set (circular dependency)
  email_varset_workspace_ids = [
    tfe_workspace.aws.id,
    tfe_workspace.github.id,
  ]

}
