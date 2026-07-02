# TellersTechOrg/tellerstech-website — WordPress site files (imported; pre-existing repo).
# Branch protection is not managed here: private repos on the current GitHub plan
# return 403 from the branch protection API (requires GitHub Pro or public repo).

import {
  to       = github_repository.tellerstech-website
  id       = "tellerstech-website"
  provider = github.tellerstechorg
}

import {
  to       = github_branch_default.tellerstech-website-main
  id       = "tellerstech-website:main"
  provider = github.tellerstechorg
}

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
