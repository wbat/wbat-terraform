# TellersTechOrg/ysn-tsn-website — ysn.io + tsn.io shorteners (imported).
# Branch protection is managed below. Private repos need GitHub Team (or public
# visibility) for the protection API; free-plan orgs return 403 until upgraded.
# One-time imports removed after apply. No PR CI — status checks omitted.

resource "github_repository" "ysn-tsn-website" {
  provider = github.tellerstechorg

  name         = "ysn-tsn-website"
  description  = "ysn.io + tsn.io link shorteners (one codebase, two vhosts)"
  homepage_url = "https://tsn.io/"
  visibility   = "private"

  has_issues    = true
  has_wiki      = false
  has_projects  = true
  has_downloads = false

  delete_branch_on_merge = true

  allow_merge_commit  = true
  allow_squash_merge  = true
  allow_rebase_merge  = true
  allow_auto_merge    = false
  allow_update_branch = true
}

resource "github_branch_default" "ysn-tsn-website-main" {
  provider   = github.tellerstechorg
  repository = github_repository.ysn-tsn-website.name
  branch     = "main"
}

resource "github_branch_protection" "ysn-tsn-website-main" {
  provider = github.tellerstechorg

  repository_id  = github_repository.ysn-tsn-website.node_id
  pattern        = "main"
  enforce_admins = false

  require_conversation_resolution = true

  required_pull_request_reviews {
    dismiss_stale_reviews           = true
    required_approving_review_count = 0
  }
}
