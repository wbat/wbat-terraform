resource "github_organization_settings" "wbat" {
  name        = "WBAT, LLC"
  description = "Based in Greencastle, PA"

  billing_email = var.personal_email
  blog          = "http://www.wbat.net"
  location      = "United States of America"

  default_repository_permission                            = "none"
  dependabot_alerts_enabled_for_new_repositories           = true
  dependabot_security_updates_enabled_for_new_repositories = true
  dependency_graph_enabled_for_new_repositories            = true
  members_can_create_private_repositories                  = false
  members_can_create_public_repositories                   = false
  members_can_create_repositories                          = false
}
