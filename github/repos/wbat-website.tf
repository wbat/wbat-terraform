# wbat/wbat-website — marketing site for wbat.net (imported; pre-existing repo).
# Branch protection is managed below. Private repos need GitHub Team (or public
# visibility) for the protection API; free-plan orgs return 403 until upgraded.
# One-time imports removed after apply.

resource "github_repository" "wbat-website" {
  name         = "wbat-website"
  description  = "WBAT.net website"
  homepage_url = "https://www.wbat.net/"
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

resource "github_branch_default" "wbat-website-main" {
  repository = github_repository.wbat-website.name
  branch     = "main"
}

resource "github_branch_protection" "wbat-website-main" {
  repository_id  = github_repository.wbat-website.node_id
  pattern        = "main"
  enforce_admins = false

  require_conversation_resolution = true

  required_pull_request_reviews {
    dismiss_stale_reviews           = true
    required_approving_review_count = 0
  }

  required_status_checks {
    contexts = ["PHP lint & smoke"]
    strict   = true
  }
}
