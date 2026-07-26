# AGENTS.md

## Cursor Cloud specific instructions

This repo is **Terraform Infrastructure as Code** (no runnable app). Real applies happen in **HCP Terraform**, not locally. There are three independent workspaces: `aws/`, `github/`, `tfc/`. All modules are local paths (no git/SSH module sources), so init/validate work offline without any secrets.

### Toolchain
- Terraform is pinned to the version in `.terraform-version` (currently `1.15.7`). The startup update script installs it to `/usr/local/bin/terraform`.
- `python3` + `PyYAML` are already present in the base image (used only by optional `scripts/`).

### Lint / validate / "build" (the core dev loop)
- Lint (from repo root): `terraform fmt -recursive -check`
- Per workspace validate (run inside `aws/`, `github/`, or `tfc/`):
  - `terraform init -backend=false` then `terraform validate`
- Use `-backend=false` for local validation. Plain `terraform init` (and any `plan`/`apply`) targets the HCP Terraform cloud backend and needs a `TFC_API_TOKEN`; do not attempt real plan/apply here. CI mirrors this: fmt from root + init/validate per workspace (see `.github/workflows/terraform_ci.yml`).

### Gotchas
- `terraform init` appends a platform-specific `h1:` hash to each `.terraform.lock.hcl`. This is local noise — do not commit it (revert with `git checkout -- '*/.terraform.lock.hcl'`).
- No automated test suite exists; validation = `fmt -check` + `validate` across the three workspaces.
- `scripts/` (EC2 volume-shrink migration tooling) is optional ops tooling, not part of the Terraform loop; it only needs `python3` + `PyYAML`.
