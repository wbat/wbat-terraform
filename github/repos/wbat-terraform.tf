resource "github_repository" "wbat-terraform" {
  name        = "wbat-terraform"
  description = "WBAT Terraform Repo"
  visibility  = "public"

  has_issues           = true
  has_wiki             = true
  has_downloads        = true
  has_projects         = true
  vulnerability_alerts = true

  delete_branch_on_merge = true

  topics = [
    "aws",
    "hcl",
    "terraform",
    "terraform-aws",
    "terraform-cloud",
    "terraform-github",
  ]
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
    contexts = [
      # TFC
      "Terraform Cloud/WBAT/wbat-terraform-aws",
      "Terraform Cloud/WBAT/wbat-terraform-github",
      "Terraform Cloud/WBAT/wbat-terraform-tfc",

      # Github Actions (version-independent names; see aws/docs/terraform-version-upgrade.md)
      "Format",
      "Validate (aws)",
      "Validate (github)",
      "Validate (tfc)",
    ]
    strict = true
  }
}

# Default Branch
resource "github_branch_default" "wbat-terraform-main" {
  repository = github_repository.wbat-terraform.name
  branch     = "main"
}
