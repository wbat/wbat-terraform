resource "tfe_variable_set" "email_addresses" {
  name         = "Email Addresses"
  description  = "Email address variables (to limit spam exposure)"
  organization = tfe_organization.wbat.id
}

# Personal Email (brianateller@gmail.com) - for billing and admin notifications
resource "tfe_variable" "personal_email" {
  key             = "personal_email"
  value           = ""
  category        = "terraform"
  description     = "Personal email address for billing and admin notifications"
  variable_set_id = tfe_variable_set.email_addresses.id

  lifecycle {
    ignore_changes = [value]
  }
}

# TellersTech Email (tellerstech@gmail.com) - for business notifications
resource "tfe_variable" "tellerstech_email" {
  key             = "tellerstech_email"
  value           = ""
  category        = "terraform"
  description     = "TellersTech email address for business notifications"
  variable_set_id = tfe_variable_set.email_addresses.id

  lifecycle {
    ignore_changes = [value]
  }
}

resource "tfe_workspace_variable_set" "email_addresses" {
  for_each = toset(local.tfc-workspace_ids)

  variable_set_id = tfe_variable_set.email_addresses.id

  workspace_id = each.key
}
