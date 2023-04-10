resource "github_repository" "wbat-terraform" {
  name        = "wbat-terraform"
  description = "WBAT Terraform Repo"
  visibility  = "public"

  has_issues           = true
  has_wiki             = true
  has_downloads        = true
  has_projects         = true
  vulnerability_alerts = true

}

# Manage branch protection
resource "github_branch_protection" "wbat-terraform-main" {
  repository_id  = github_repository.wbat-terraform.node_id
  pattern        = "main"
  enforce_admins = false

  require_conversation_resolution = true

  required_pull_request_reviews {
    dismiss_stale_reviews           = true
    required_approving_review_count = 0
  }

  required_status_checks {
    contexts = []
    strict   = true
  }
}

# Default Branch
resource "github_branch_default" "wbat-terraform-main" {
  repository = github_repository.wbat-terraform.name
  branch     = "main"
}
