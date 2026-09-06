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
- Use `-backend=false` for local validation. Plain `terraform init` (and any `plan`/`apply`) targets the HCP Terraform cloud backend and needs a token in `TF_TOKEN_app_terraform_io`; do not attempt real plan/apply here. CI mirrors this: fmt from root + init/validate per workspace (see `.github/workflows/terraform_ci.yml`).

### Visibility into the running system (optional, credential-gated)
The offline loop above never needs credentials. Seeing the live system does, and that access is opt-in per environment — so check what you actually have before planning work that depends on it.
- `.cursor/start.sh` runs at boot and logs which of AWS, HCP Terraform, and Tailscale are usable. Read `/tmp/cursor/start-user/start-user.log` first rather than discovering a missing credential mid-investigation.
- When AWS is available it is **read-only by design** (`aws/global/iam/user-CursorAgent.tf`): no writes, and an explicit deny on `s3:GetObject`, `secretsmanager:GetSecretValue`, and `kms:Decrypt`. Do not try to route around that deny; it is the reason the credential is safe to hand out.
- Shell access is `aws ssm start-session`, not SSH, and may be switched off (`cursor_agent_shell_access`). It lands as `ssm-user` with sudo on a box serving ~91 production sites — treat it as production, and prefer read-only diagnosis.
- Setup, verification commands, and revocation are documented in [aws/docs/cloud-agent-access.md](aws/docs/cloud-agent-access.md).

### Gotchas
- `terraform init` appends a platform-specific `h1:` hash to each `.terraform.lock.hcl`. This is local noise — do not commit it (revert with `git checkout -- '*/.terraform.lock.hcl'`).
- No automated test suite exists; validation = `fmt -check` + `validate` across the three workspaces.
- `scripts/` (EC2 volume-shrink migration tooling) is optional ops tooling, not part of the Terraform loop; it only needs `python3` + `PyYAML`.
