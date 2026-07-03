module "iterm2_git_status_bar" {
  source = "./modules/repository"

  name        = "iTerm2-Git-Status-Bar"
  description = "This repository contains a custom script that provides a more reliable and full-featured Git status bar component for iTerm2"

  topics = [
    "bash",
    "iterm",
    "iterm2",
    "iterm2-component",
    "iterm2-status",
    "iterm2-statusbar",
    "statusbar",
  ]

  manage_branch_protection       = true
  required_status_check_contexts = ["sh-checker"]
}
