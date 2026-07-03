resource "github_repository" "this" {
  name         = var.name
  description  = var.description
  homepage_url = var.homepage_url
  visibility   = var.visibility
  topics       = var.topics

  has_issues    = var.has_issues
  has_wiki      = var.has_wiki
  has_projects  = var.has_projects
  has_downloads = var.has_downloads

  vulnerability_alerts = var.vulnerability_alerts

  delete_branch_on_merge = var.delete_branch_on_merge
}

resource "github_branch_default" "this" {
  repository = github_repository.this.name
  branch     = var.default_branch
}

resource "github_branch_protection" "this" {
  count = var.manage_branch_protection ? 1 : 0

  repository_id  = github_repository.this.node_id
  pattern        = var.branch_protection_pattern
  enforce_admins = var.enforce_admins

  require_conversation_resolution = var.require_conversation_resolution

  required_pull_request_reviews {
    dismiss_stale_reviews           = var.dismiss_stale_reviews
    required_approving_review_count = var.required_approving_review_count
  }

  dynamic "required_status_checks" {
    for_each = length(var.required_status_check_contexts) > 0 ? [1] : []
    content {
      contexts = var.required_status_check_contexts
      strict   = true
    }
  }
}
