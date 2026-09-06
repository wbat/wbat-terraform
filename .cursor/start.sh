#!/usr/bin/env bash
# Per-boot runtime setup for wbat-terraform Cloud Agents.
#
# Two jobs: bring up tailscaled (a live daemon, so it cannot come from install.sh or
# survive in a snapshot), and report which of the three visibility paths are actually
# usable so an agent learns that from the start log instead of from a failed command
# twenty minutes in.
#
# Deliberately exits 0 even when every credential is missing. A failing start blocks the
# environment from coming up, and the ordinary use of this repo -- fmt, init -backend=false,
# validate -- needs no credentials at all. Missing access degrades capability; it must not
# cost the user a working agent.

set -uo pipefail

log() { printf '[start] %s\n' "$*"; }

# --- Tailscale ---------------------------------------------------------------------
if [ -n "${TS_AUTHKEY:-}" ]; then
  if pgrep -x tailscaled >/dev/null 2>&1; then
    log "tailscaled already running"
  else
    # Userspace networking is required: Cloud Agent VMs cannot use a TUN interface even
    # though /dev/net/tun exists. The SOCKS5/HTTP listener on 1055 is how anything that
    # is not routed through `tailscale nc` reaches the tailnet.
    log "starting tailscaled (userspace networking, SOCKS5 on 127.0.0.1:1055)"
    sudo mkdir -p /var/lib/tailscale
    sudo sh -c 'nohup tailscaled \
      --tun=userspace-networking \
      --socks5-server=localhost:1055 \
      --outbound-http-proxy-listen=localhost:1055 \
      --statedir=/var/lib/tailscale \
      >/var/log/tailscaled.log 2>&1 &'

    for _ in $(seq 1 30); do
      sudo tailscale status >/dev/null 2>&1 && break
      # "Logged out" is also a ready daemon -- status exits non-zero until the socket
      # answers at all, which is the condition being waited on.
      sudo tailscale status 2>&1 | grep -q 'Logged out' && break
      sleep 1
    done
  fi

  if [ "$(sudo tailscale status --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null)" = "Running" ]; then
    log "tailscale already authenticated"
  else
    # --shields-up: this node only ever originates connections. Nothing should be able
    # to reach an ephemeral agent VM.
    # --accept-dns=false: leaves container DNS alone. MagicDNS names still resolve for
    # `tailscale nc`, which asks tailscaled directly rather than going through resolv.conf.
    log "authenticating to tailnet"
    if sudo tailscale up \
      --auth-key="${TS_AUTHKEY}" \
      --hostname="cursor-agent-$(hostname | tr -cd 'a-z0-9-' | cut -c1-12)" \
      --shields-up \
      --accept-dns=false \
      --timeout=45s 2>&1 | sed 's/^/[start] tailscale: /'; then
      log "OK tailnet up: $(sudo tailscale ip -4 2>/dev/null | head -1)"
    else
      # Most likely an expired, already-consumed, or non-pre-approved auth key. Report
      # it and continue; SSM is the other shell path.
      log "WARN tailscale up failed -- tailnet SSH unavailable this session"
    fi
  fi
else
  log "TS_AUTHKEY unset -- skipping Tailscale (use SSM for shell access)"
fi

# --- AWS ---------------------------------------------------------------------------
# Proves the credentials work now rather than letting the first real query fail. Read-only
# call, no mutation.
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  if ident="$(aws sts get-caller-identity --query Arn --output text 2>&1)"; then
    log "OK aws credentials valid: ${ident}"
  else
    # Collapsed to one line: the CLI's multi-line error would otherwise break up the
    # start log and bury the reason.
    log "WARN aws credentials present but rejected: $(printf '%s' "$ident" | tr '\n' ' ')"
  fi
else
  log "AWS_ACCESS_KEY_ID unset -- no metrics/logs/SSM access"
fi

# --- Terraform Cloud ---------------------------------------------------------------
# TF_TOKEN_app_terraform_io is the name the Terraform CLI consumes natively for the
# app.terraform.io cloud backend, and it doubles as the API bearer token for reading
# plans. One secret, no ~/.terraformrc to write.
if [ -n "${TF_TOKEN_app_terraform_io:-}" ]; then
  # Branch on the HTTP status, not on whether a username came back. A team token is
  # legitimate here but has no /account/details identity, so "no identity" alone cannot
  # distinguish a scoped team token from a revoked one -- and reporting an expired token
  # as fine is the failure that would waste the most time later.
  tfc_body="$(mktemp)"
  tfc_code="$(curl -sS -o "$tfc_body" -w '%{http_code}' \
    -H "Authorization: Bearer ${TF_TOKEN_app_terraform_io}" \
    https://app.terraform.io/api/v2/account/details 2>/dev/null)"
  case "$tfc_code" in
    200)
      log "OK terraform cloud token valid ($(jq -r '.data.attributes.username // "user"' "$tfc_body" 2>/dev/null))"
      ;;
    401)
      log "WARN terraform cloud token rejected (401) -- expired or revoked; cannot read plans"
      ;;
    *)
      # 403/404 is the normal answer for a team or organization token, which has no user
      # identity but can still read workspaces and runs.
      log "NOTE terraform cloud token present (HTTP ${tfc_code} on /account/details, expected for a team token)"
      ;;
  esac
  rm -f "$tfc_body"
else
  log "TF_TOKEN_app_terraform_io unset -- cannot read HCP Terraform plans"
fi

log "done"
exit 0
