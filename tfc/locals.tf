locals {

  tfc-workspace_ids = [
    tfe_workspace.aws.id,
    tfe_workspace.github.id,
    tfe_workspace.tfc.id,
  ]

}
