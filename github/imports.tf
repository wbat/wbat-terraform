# One-time imports for pre-existing TellersTechOrg resources.
# Remove this file after a successful wbat-terraform-github apply.
#
# Import blocks must live in the root module (not repos/) and must not set
# provider — the target resource's provider mapping is used automatically.

import {
  to = module.repos.github_repository.tellerstech-website
  id = "tellerstech-website"
}

# github_branch_default import id is repository name only (not repo:branch).
import {
  to = module.repos.github_branch_default.tellerstech-website-main
  id = "tellerstech-website"
}
