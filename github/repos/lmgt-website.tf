# TellersTechOrg/lmgt-website — lmgt.com gag site (imported; pre-existing repo).
# lmgt.org awards vanity stays with tellerstech-website.
# Branch protection is managed below. Private repos need GitHub Team (or public
# visibility) for the protection API; free-plan orgs return 403 until upgraded.
# One-time imports removed after apply. No PR CI — status checks omitted.

resource "github_repository" "lmgt-website" {
  provider = github.tellerstechorg

  name         = "lmgt-website"
  description  = "lmgt.com gag site (lmgt.org stays on tellerstech.com/awards)"
  homepage_url = "https://www.lmgt.com/"
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

resource "github_branch_default" "lmgt-website-main" {
  provider   = github.tellerstechorg
  repository = github_repository.lmgt-website.name
  branch     = "main"
}

resource "github_branch_protection" "lmgt-website-main" {
  provider = github.tellerstechorg

  repository_id  = github_repository.lmgt-website.node_id
  pattern        = "main"
  enforce_admins = false

  require_conversation_resolution = true

  required_pull_request_reviews {
    dismiss_stale_reviews           = true
    required_approving_review_count = 0
  }
}
