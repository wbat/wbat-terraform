# SES inbound allowlist / alerts — AWS workspace only.
# Values are set in the TFC UI (ignore_changes); nothing sensitive belongs in git.

resource "tfe_variable_set" "ses_inbound" {
  name         = "SES Inbound"
  description  = "SES inbound receive/forward variables for the AWS workspace (set values in TFC UI)"
  organization = tfe_organization.wbat.id
}

resource "tfe_variable" "enable_inbound_forwarding" {
  key             = "enable_inbound_forwarding"
  value           = "false"
  category        = "terraform"
  hcl             = true
  sensitive       = false
  description     = "When true, provision SES inbound gate/worker and receipt rules"
  variable_set_id = tfe_variable_set.ses_inbound.id

  lifecycle {
    ignore_changes = [value]
  }
}

resource "tfe_variable" "inbound_recipients" {
  key             = "inbound_recipients"
  value           = "[]"
  category        = "terraform"
  hcl             = true
  sensitive       = true
  description     = "Allowlisted local addresses for SES receipt rules (HCL list)"
  variable_set_id = tfe_variable_set.ses_inbound.id

  lifecycle {
    ignore_changes = [value]
  }
}

resource "tfe_variable" "inbound_alert_email" {
  key             = "inbound_alert_email"
  value           = ""
  category        = "terraform"
  sensitive       = true
  description     = "Optional SNS email subscriber for inbound flood/error alarms"
  variable_set_id = tfe_variable_set.ses_inbound.id

  lifecycle {
    ignore_changes = [value]
  }
}

resource "tfe_workspace_variable_set" "aws_ses_inbound" {
  workspace_id    = tfe_workspace.aws.id
  variable_set_id = tfe_variable_set.ses_inbound.id
}
