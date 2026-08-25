# wbat/wbat-website — marketing site for wbat.net (imported; pre-existing repo).
# Branch protection is not managed here: private repos on the current GitHub plan
# return 403 from the branch protection / rulesets API (requires GitHub Pro or
# a public repo). Import blocks live in ../imports.tf (root module).

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
