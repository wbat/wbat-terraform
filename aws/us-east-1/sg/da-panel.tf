# DirectAdmin panel ingress on 2222.
#
# 2222 is the highest-value target on the primary: a password login, with
# account names that are permanently public in this repository's git history,
# where a success is account takeover rather than a shell on one site. CSF's lfd
# rate-limits it (LF_DIRECTADMIN), but rate limiting is a delay, not a boundary.
#
# These rules are the boundary. They are separate resources rather than inline
# `ingress` blocks in aws_security_group.default on purpose: that group declares
# no rules, so its ingress is computed and Terraform adopts whatever exists.
# Adding an inline block would make the provider treat the declared set as the
# complete set and revoke every rule not written down here -- including 80, 443
# and 22. That is an immediate outage for every site on the box.
#
# Adding these rules does NOT close 2222. The existing 0.0.0.0/0 rule was
# created outside Terraform and is not in state, so no apply will remove it.
# Revoking it is a deliberate second step, taken only after these rules are
# applied and verified. Order is in aws/docs/host-access-hardening.md.

locals {
  # Both instances share this security group, so the private path between them
  # is covered by the self-reference below. These cover the other path: a
  # connection made to server.wbat.net or server2.wbat.net by hostname resolves
  # to the public address, leaves through the internet gateway, and arrives from
  # the EIP rather than the private address.
  da_panel_server_cidrs = {
    "server.wbat.net"  = "${var.primary_public_ip}/32"
    "server2.wbat.net" = "${var.secondary_public_ip}/32"
  }
}

resource "aws_vpc_security_group_ingress_rule" "da_panel_operator" {
  for_each = var.da_panel_allowed_cidrs

  security_group_id = aws_security_group.default.id
  description       = "DirectAdmin panel 2222 — ${each.key}"
  ip_protocol       = "tcp"
  from_port         = 2222
  to_port           = 2222
  cidr_ipv4         = each.value

  tags = merge(
    var.core_tags,
    {
      Name       = "da-panel-2222-${each.key}",
      "scm:file" = "aws/us-east-1/sg/da-panel.tf",
    },
  )
}

resource "aws_vpc_security_group_ingress_rule" "da_panel_servers" {
  for_each = local.da_panel_server_cidrs

  security_group_id = aws_security_group.default.id
  description       = "DirectAdmin panel 2222 — ${each.key} (public path)"
  ip_protocol       = "tcp"
  from_port         = 2222
  to_port           = 2222
  cidr_ipv4         = each.value

  tags = merge(
    var.core_tags,
    {
      Name       = "da-panel-2222-${each.key}",
      "scm:file" = "aws/us-east-1/sg/da-panel.tf",
    },
  )
}

# The private path between the two instances. A security-group reference rather
# than a private CIDR: it keeps working across a private-IP change, which this
# estate has already had once -- the stale 172.30.0.87 on the primary is what
# caused the catch-all vhost regression.
resource "aws_vpc_security_group_ingress_rule" "da_panel_self" {
  security_group_id            = aws_security_group.default.id
  description                  = "DirectAdmin panel 2222 — instances in this security group (private path)"
  ip_protocol                  = "tcp"
  from_port                    = 2222
  to_port                      = 2222
  referenced_security_group_id = aws_security_group.default.id

  tags = merge(
    var.core_tags,
    {
      Name       = "da-panel-2222-intra-sg",
      "scm:file" = "aws/us-east-1/sg/da-panel.tf",
    },
  )
}
