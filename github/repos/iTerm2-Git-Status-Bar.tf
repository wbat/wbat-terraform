resource "github_repository" "iTerm2-Git-Status-Bar" {
  name        = "iTerm2-Git-Status-Bar"
  description = "This repository contains a custom script that provides a more reliable and full-featured Git status bar component for iTerm2"
  visibility  = "public"

  has_issues           = true
  has_wiki             = true
  has_downloads        = true
  has_projects         = true
  vulnerability_alerts = true

  topics = [
    "bash",
    "iterm",
    "iterm2",
    "iterm2-component",
    "iterm2-status",
    "iterm2-statusbar",
    "statusbar",
  ]

}

# Manage branch protection
resource "github_branch_protection" "iTerm2-Git-Status-Bar-main" {
  repository_id  = github_repository.iTerm2-Git-Status-Bar.node_id
  pattern        = "main"
  enforce_admins = false

  require_conversation_resolution = true

  required_pull_request_reviews {
    dismiss_stale_reviews           = true
    required_approving_review_count = 0
  }

  required_status_checks {
    contexts = [
      # Github Actions
      "sh-checker"
    ]
    strict = true
  }
}

# Default Branch
resource "github_branch_default" "iTerm2-Git-Status-Bar-main" {
  repository = github_repository.iTerm2-Git-Status-Bar.name
  branch     = "main"
}
