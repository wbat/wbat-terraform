# One-time imports for pre-existing GitHub repositories.
# After a successful wbat-terraform-github apply, comment out or remove the
# corresponding blocks (per repository convention).
#
# Import blocks must live in the root module (not repos/) and must not set
# provider — the target resource's provider mapping is used automatically.
# github_repository import id is the repository name; github_branch_default
# import id is also the repository name (not repo:branch).

# --- wbat organization ---

import {
  to = module.repos.module.iterm_status.github_repository.this
  id = "iterm-status"
}
import {
  to = module.repos.module.iterm_status.github_branch_default.this
  id = "iterm-status"
}

import {
  to = module.repos.module.java_jar_test.github_repository.this
  id = "java-jar-test"
}
import {
  to = module.repos.module.java_jar_test.github_branch_default.this
  id = "java-jar-test"
}

import {
  to = module.repos.module.stocks_to_rss.github_repository.this
  id = "stocks-to-rss"
}
import {
  to = module.repos.module.stocks_to_rss.github_branch_default.this
  id = "stocks-to-rss"
}

import {
  to = module.repos.module.osticket_rest_api.github_repository.this
  id = "osticket-rest-api"
}
import {
  to = module.repos.module.osticket_rest_api.github_branch_default.this
  id = "osticket-rest-api"
}

import {
  to = module.repos.module.stripe_terminal.github_repository.this
  id = "stripe-terminal"
}
import {
  to = module.repos.module.stripe_terminal.github_branch_default.this
  id = "stripe-terminal"
}

import {
  to = module.repos.module.rss_2_0_generation_class.github_repository.this
  id = "rss-2.0-generation-class"
}
import {
  to = module.repos.module.rss_2_0_generation_class.github_branch_default.this
  id = "rss-2.0-generation-class"
}

# --- TellersTechOrg organization ---

import {
  to = module.repos.module.terraform_module_example.github_repository.this
  id = "terraform_module_example"
}
import {
  to = module.repos.module.terraform_module_example.github_branch_default.this
  id = "terraform_module_example"
}
