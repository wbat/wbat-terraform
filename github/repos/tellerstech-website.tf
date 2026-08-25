# TellersTechOrg/tellerstech-website — WordPress site files (imported; pre-existing repo).
# Branch protection is managed below. Private repos need GitHub Team (or public
# visibility) for the protection API; free-plan orgs return 403 until upgraded.
# One-time imports removed after apply. PR CI is path-filtered (PHP / OCB / e2e),
# so required_status_checks are omitted to avoid blocking unrelated PRs.

resource "github_repository" "tellerstech-website" {
  provider = github.tellerstechorg

  name        = "tellerstech-website"
  description = "The WordPress Files for TellersTech.com (and ShipItWeekly.fm, OnCallBrief.com, and CodeDuck.ai)"
  visibility  = "private"

  has_issues    = true
  has_wiki      = false
  has_projects  = true
  has_downloads = true

  delete_branch_on_merge = true

  allow_merge_commit  = true
  allow_squash_merge  = true
  allow_rebase_merge  = true
  allow_auto_merge    = false
  allow_update_branch = true
}

resource "github_branch_default" "tellerstech-website-main" {
  provider   = github.tellerstechorg
  repository = github_repository.tellerstech-website.name
  branch     = "main"
}

resource "github_branch_protection" "tellerstech-website-main" {
  provider = github.tellerstechorg

  repository_id  = github_repository.tellerstech-website.node_id
  pattern        = "main"
  enforce_admins = false

  require_conversation_resolution = true

  required_pull_request_reviews {
    dismiss_stale_reviews           = true
    required_approving_review_count = 0
  }
}
