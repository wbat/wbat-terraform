resource "tfe_organization" "wbat" {
  name  = "wbat"
  email = var.email_address

  allow_force_delete_workspaces = true

}
