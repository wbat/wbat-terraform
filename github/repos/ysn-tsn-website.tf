# TellersTechOrg/ysn-tsn-website — ysn.io + tsn.io shorteners (imported).
# Branch protection is not managed here (private repo on free plan → 403).
# Import blocks live in ../imports.tf (root module).

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
