# State moves for repositories refactored into the ./modules/repository module.
# These keep the existing resources in place (no destroy/recreate) as their
# addresses change from top-level resources to module resources.

moved {
  from = github_repository.wbat-terraform
  to   = module.wbat_terraform.github_repository.this
}

moved {
  from = github_branch_default.wbat-terraform-main
  to   = module.wbat_terraform.github_branch_default.this
}

moved {
  from = github_branch_protection.wbat-terraform-main
  to   = module.wbat_terraform.github_branch_protection.this[0]
}

moved {
  from = github_repository.iTerm2-Git-Status-Bar
  to   = module.iterm2_git_status_bar.github_repository.this
}

moved {
  from = github_branch_default.iTerm2-Git-Status-Bar-main
  to   = module.iterm2_git_status_bar.github_branch_default.this
}

moved {
  from = github_branch_protection.iTerm2-Git-Status-Bar-main
  to   = module.iterm2_git_status_bar.github_branch_protection.this[0]
}
