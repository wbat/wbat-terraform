# GitHub workspace (`wbat/wbat-terraform` → `github/`)

Terraform manages WBAT org repositories and shared settings.

## Branch protection (Team plan required)

Private repositories on GitHub Free/Pro **cannot** use organization-level branch protection rules via the API (403 on apply). Terraform resources for `github_branch_protection` were removed in [#108](https://github.com/wbat/wbat-terraform/pull/108) after apply failed.

Until the org upgrades to **GitHub Team** (or repos are public):

- Enforce `main` protection manually in the GitHub UI for critical repos, or
- Re-introduce `github_branch_protection` resources in `repos/modules/repository/` once the plan supports it.

Imported website repos (`wbat-website`, `lmgt-website`, `ysn-tsn-website`, `tellerstech-website`) still receive `delete_branch_on_merge`, `allow_update_branch`, and homepage URLs from Terraform.
