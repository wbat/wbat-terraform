# Terraform version upgrades

HCP Terraform and this repo are upgraded in **small PRs** so branch protection and workspace pins do not block each other.

## Current targets

| Layer | Version |
|-------|---------|
| HCP Terraform workspaces | 1.14.3 (see `tfc/tfc-workspace-*.tf`) |
| GitHub Actions CI | ~1.14 |
| `required_version` in workspace `versions.tf` | >= 1.10 |

## Incremental upgrade to 1.15.7

Merge in order:

1. **Stable CI check names** — Remove Terraform version from GitHub Actions matrix job names (`Format`, `Validate (aws)`, …). Future TF bumps no longer require branch-protection renames. *May need one admin merge bypass while `main` still lists old `~1.14` check names.*
2. **Tooling 1.15** — Bump CI/Infracost to `~1.15`, `required_version` to `>= 1.15.0`, add `.terraform-version`, update README. No TFC or branch-protection changes.
3. **HCP Terraform 1.15.7** — Set `local.terraform_version` in `tfc/locals.tf` and apply via `wbat-terraform-tfc`.

After step 3, apply `wbat-terraform-github` if step 1 updated required status checks (step 1 includes that change).

## Local validation

```bash
terraform version   # or use .terraform-version with tfenv/asdf after step 2
cd aws && terraform init -backend=false && terraform validate
```
