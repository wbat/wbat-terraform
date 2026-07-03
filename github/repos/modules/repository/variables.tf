variable "name" {
  description = "Repository name."
  type        = string
}

variable "description" {
  description = "Repository description."
  type        = string
  default     = null
}

variable "homepage_url" {
  description = "Repository homepage URL."
  type        = string
  default     = null
}

variable "visibility" {
  description = "Repository visibility: public, private, or internal."
  type        = string
  default     = "public"
}

variable "topics" {
  description = "Repository topics."
  type        = list(string)
  default     = []
}

variable "has_issues" {
  description = "Enable GitHub Issues."
  type        = bool
  default     = true
}

variable "has_wiki" {
  description = "Enable the repository wiki."
  type        = bool
  default     = true
}

variable "has_projects" {
  description = "Enable repository projects."
  type        = bool
  default     = true
}

variable "has_downloads" {
  description = "Enable repository downloads."
  type        = bool
  default     = true
}

variable "vulnerability_alerts" {
  description = "Enable Dependabot vulnerability alerts. Not supported on private repos without GitHub Advanced Security."
  type        = bool
  default     = true
}

variable "delete_branch_on_merge" {
  description = "Automatically delete head branches after PRs are merged."
  type        = bool
  default     = true
}

variable "default_branch" {
  description = "Default branch name."
  type        = string
  default     = "main"
}

variable "manage_branch_protection" {
  description = "Whether to manage a branch protection rule for this repository."
  type        = bool
  default     = false
}

variable "branch_protection_pattern" {
  description = "Branch pattern the protection rule applies to."
  type        = string
  default     = "main"
}

variable "enforce_admins" {
  description = "Enforce branch protection rules on administrators."
  type        = bool
  default     = false
}

variable "require_conversation_resolution" {
  description = "Require conversation resolution before merging."
  type        = bool
  default     = true
}

variable "dismiss_stale_reviews" {
  description = "Dismiss stale pull request approvals when new commits are pushed."
  type        = bool
  default     = true
}

variable "required_approving_review_count" {
  description = "Number of approving reviews required to merge."
  type        = number
  default     = 0
}

variable "required_status_check_contexts" {
  description = "Status checks that must pass before merging. Empty disables the required_status_checks block."
  type        = list(string)
  default     = []
}
