#!/usr/bin/env bash
# Per-boot runtime setup for wbat-terraform Cloud Agents.
#
# Reports which visibility paths are actually usable, so an agent learns that from the
# start log instead of from a failed command twenty minutes into an investigation.
#
# No daemons to launch: shell access is `aws ssm start-session`, which needs nothing
# running locally beyond the Session Manager plugin that install.sh places.
#
# Deliberately exits 0 even when every credential is missing. A failing start blocks the
# environment from coming up, and the ordinary use of this repo -- fmt, init -backend=false,
# validate -- needs no credentials at all. Missing access degrades capability; it must not
# cost the user a working agent.

set -uo pipefail

log() { printf '[start] %s\n' "$*"; }

# --- AWS ---------------------------------------------------------------------------
# Proves the credentials work now rather than letting the first real query fail. Read-only
# call, no mutation.
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  if ident="$(aws sts get-caller-identity --query Arn --output text 2>&1)"; then
    log "OK aws credentials valid: ${ident}"

    # With Tailscale out of the picture, Session Manager is the only shell path, so
    # confirm it end to end rather than at the credential layer only. An instance whose
    # SSM agent has stopped is invisible here while still serving traffic -- and that is
    # precisely the situation where a shell is wanted.
    # shellcheck disable=SC2016  # single quotes are required: the backticks are JMESPath
    if ssm_online="$(aws ssm describe-instance-information \
      --query 'InstanceInformationList[?PingStatus==`Online`].InstanceId' \
      --output text 2>/dev/null)"; then
      if [ -n "$ssm_online" ]; then
        log "OK ssm shell available: ${ssm_online}"
      else
        log "WARN no instance reports an Online SSM agent -- telemetry works, shell does not"
      fi
    else
      # Reachable if the credential is ever narrowed to telemetry without SSM; not
      # expected under the current admin key, so it is worth surfacing rather than
      # swallowing.
      log "NOTE ssm describe not permitted -- telemetry only, no shell path"
    fi
  else
    # Collapsed to one line: the CLI's multi-line error would otherwise break up the
    # start log and bury the reason.
    log "WARN aws credentials present but rejected: $(printf '%s' "$ident" | tr '\n' ' ' | tr -s ' ' | sed 's/^ *//')"
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
