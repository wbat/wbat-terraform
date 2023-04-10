resource "tfe_variable_set" "email_address" {
  name         = "Email Address"
  description  = "Variables for Email Address (to limit spam)"
  organization = tfe_organization.wbat.id
}

# Email Address
resource "tfe_variable" "email_address-email_address" {
  key             = "email_address"
  value           = ""
  category        = "terraform"
  description     = "Organization Email Address"
  sensitive       = true
  variable_set_id = tfe_variable_set.email_address.id

  lifecycle {
    ignore_changes = [value]
  }
}

resource "tfe_workspace_variable_set" "email_address" {
  for_each = toset(local.tfc-workspace_ids)

  variable_set_id = tfe_variable_set.email_address.id

  workspace_id = each.key
}
