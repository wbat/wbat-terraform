/*
This is the SSH key that a workspace needs in order to git clone a module.
This datasource and reference to it can be removed from workspaces once we move fully to
private versioned modules.
*/

data "tfe_ssh_key" "WBAT" {
  name         = "WBAT"
  organization = "WBAT"

}
