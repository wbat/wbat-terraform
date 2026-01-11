resource "tfe_organization" "wbat" {
  name  = "wbat"
  email = var.personal_email

  allow_force_delete_workspaces = true
}
