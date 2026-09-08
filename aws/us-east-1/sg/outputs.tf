output "da_panel_allowed_sources" {
  description = "Every source Terraform allows to reach the DirectAdmin panel on 2222. Verify this is what you expect BEFORE revoking the pre-existing 0.0.0.0/0 rule, which is not managed here."
  value = concat(
    [for k, v in var.da_panel_allowed_cidrs : "${k} = ${v}"],
    [for k, v in local.da_panel_server_cidrs : "${k} = ${v}"],
    ["intra-security-group = ${aws_security_group.default.id}"],
  )
}
