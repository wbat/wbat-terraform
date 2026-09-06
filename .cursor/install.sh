#!/usr/bin/env bash
# Cloud Agent environment bootstrap for wbat-terraform.
#
# Installs the tooling an agent needs for visibility into the running system: the AWS
# CLI (metrics, logs, Cost Explorer) and the Session Manager plugin (shell on both EC2
# boxes without inbound ports or SSH keys).
#
# Deliberately no Tailscale. Both servers are on the tailnet, but reaching them that way
# from an agent would mean a tailnet node per VM plus a TS_AUTHKEY that expires every 90
# days, to obtain shell access Session Manager already provides -- and SSH itself would
# still want a private key on the VM. Tailscale remains the human path; see
# aws/docs/cloud-agent-access.md.
#
# Runs after checkout and must be idempotent and non-interactive: it may run repeatedly,
# against cached state, or as the baseline for an environment build. Everything here is
# durable filesystem state -- no daemons, no credentials. Per-boot work lives in
# start.sh, and secrets arrive as environment variables from the Cloud Agent dashboard.
#
# Nothing here needs a credential, which is deliberate: user-scoped secrets are not
# available during environment builds, and this is where builds run.

set -euo pipefail

log() { printf '[install] %s\n' "$*"; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Terraform ---------------------------------------------------------------------
# Pinned to .terraform-version, and installed here rather than assumed. A fresh Cloud
# Agent was observed booting with no terraform on PATH at all, which silently breaks the
# documented fmt/init/validate loop -- the one thing this repo always needs and the one
# thing that requires no credentials. Owning the install makes the version deterministic
# instead of dependent on whatever the base image happens to ship.
tf_want="$(tr -d '[:space:]' <"${repo_root}/.terraform-version")"
# The `|| true` is load-bearing: under `set -e` with `pipefail`, a missing terraform
# makes this pipeline fail and aborts the script before it can install anything -- so
# the cold path would break in exactly the situation it exists to fix.
tf_have="$(terraform version 2>/dev/null | head -1 | sed 's/^Terraform v//' || true)"
if [ "$tf_have" = "$tf_want" ]; then
  log "terraform ${tf_want} present"
else
  log "installing terraform ${tf_want} (found: ${tf_have:-none})"
  tmp="$(mktemp -d)"
  base="https://releases.hashicorp.com/terraform/${tf_want}"
  zip="terraform_${tf_want}_linux_amd64.zip"
  curl -fsSL "${base}/${zip}" -o "${tmp}/${zip}"
  # Verify against HashiCorp's published checksums. Skipping this would mean trusting
  # whatever the network returned for a binary that then runs against production state.
  curl -fsSL "${base}/terraform_${tf_want}_SHA256SUMS" -o "${tmp}/SHA256SUMS"
  (cd "$tmp" && grep " ${zip}\$" SHA256SUMS | sha256sum -c -)
  python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
    "${tmp}/${zip}" "$tmp"
  sudo install -m 0755 "${tmp}/terraform" /usr/local/bin/terraform
  rm -rf "$tmp"
  log "terraform installed: $(terraform version | head -1)"
fi

# --- AWS CLI v2 --------------------------------------------------------------------
# Not in the base image. The bundled installer is the only supported route on Ubuntu;
# there is no maintained apt package.
if command -v aws >/dev/null 2>&1; then
  log "aws present: $(aws --version 2>&1)"
else
  log "installing AWS CLI v2"
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
    -o "${tmp}/awscliv2.zip"
  # python3 rather than unzip: guaranteed present, and avoids another apt dependency.
  python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
    "${tmp}/awscliv2.zip" "$tmp"
  chmod +x "${tmp}/aws/install" "${tmp}/aws/dist/aws"
  sudo "${tmp}/aws/install" --update
  rm -rf "$tmp"
  log "aws installed: $(aws --version 2>&1)"
fi

# --- Session Manager plugin --------------------------------------------------------
# Required by `aws ssm start-session`. This is the preferred shell path to both
# instances: the WBAT_Main_Server profile already carries AmazonSSMManagedInstanceCore,
# so no inbound port, security-group change, or private key is involved, and every
# session is attributable in CloudTrail.
if command -v session-manager-plugin >/dev/null 2>&1; then
  log "session-manager-plugin present: $(session-manager-plugin --version 2>&1)"
else
  log "installing session-manager-plugin"
  tmp="$(mktemp -d)"
  curl -fsSL \
    "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" \
    -o "${tmp}/session-manager-plugin.deb"
  sudo dpkg -i "${tmp}/session-manager-plugin.deb"
  rm -rf "$tmp"
  log "session-manager-plugin installed: $(session-manager-plugin --version 2>&1)"
fi

# --- AWS region default ------------------------------------------------------------
# Region is not a secret, so it is configured here rather than carried as one. Written
# only when absent so a hand-edited profile is preserved.
if [ ! -f "${HOME}/.aws/config" ]; then
  log "writing ${HOME}/.aws/config (region us-east-1)"
  mkdir -p "${HOME}/.aws"
  cat >"${HOME}/.aws/config" <<'AWSCFG'
[default]
region = us-east-1
output = json
AWSCFG
else
  log "${HOME}/.aws/config present; left alone"
fi

log "done"
