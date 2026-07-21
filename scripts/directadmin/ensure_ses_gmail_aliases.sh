#!/bin/bash
# Enforce pipe-only SES Gmail forwarder aliases for managed local-parts.
#
# DirectAdmin rewrites /etc/virtual/<domain>/aliases on Forwarders UI changes.
# This script restores the required pipe destination for addresses listed in
# /etc/ses-gmail-forward/managed-aliases.conf (no mailbox addresses in git).
#
# Install:
#   install -m 755 ensure_ses_gmail_aliases.sh /usr/local/bin/ensure-ses-gmail-aliases.sh
#   install -m 600 managed-aliases.conf.example /etc/ses-gmail-forward/managed-aliases.conf
#   # edit managed-aliases.conf with real domain + local-parts
#
# Called by DA hooks (immediate) and optionally cron (safety net).

set -euo pipefail

CONFIG="${SES_GMAIL_ALIASES_CONF:-/etc/ses-gmail-forward/managed-aliases.conf}"
PIPE_VALUE='"|/usr/local/bin/ses-gmail-forward.py"'
LOG="${SES_GMAIL_ALIASES_LOG:-/var/log/ses-gmail-forward-aliases.log}"
LOCK_ROOT="${SES_GMAIL_ALIASES_LOCK_DIR:-/var/lock}"

log() {
  local msg
  msg="$(date -Iseconds) $*"
  if [[ -w "$(dirname "$LOG")" ]] 2>/dev/null || [[ -w "$LOG" ]] 2>/dev/null; then
    echo "$msg" >>"$LOG" 2>/dev/null || true
  fi
}

usage() {
  echo "Usage: $0 [domain]" >&2
  echo "  With domain: enforce that domain only (if listed in config)." >&2
  echo "  Without: enforce every domain listed in $CONFIG." >&2
}

# Strip CR and trim; ignore blank/# comments.
parse_config() {
  [[ -f "$CONFIG" ]] || {
    log "ERROR missing config $CONFIG"
    return 1
  }
  # shellcheck disable=SC2034
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # domain localpart[,localpart...]
    # shellcheck disable=SC2086
    set -- $line
    local domain="${1:-}"
    local parts="${2:-}"
    [[ -n "$domain" && -n "$parts" ]] || continue
    echo "${domain}|${parts}"
  done <"$CONFIG"
}

ensure_one() {
  local domain="$1"
  local parts_csv="$2"
  local aliases="/etc/virtual/${domain}/aliases"
  local lock="${LOCK_ROOT}/ses-gmail-aliases.${domain}.lock"
  local tmp owner mode
  local -a wanted=()
  local part

  if [[ ! -f "$aliases" ]]; then
    log "SKIP ${domain}: missing $aliases"
    return 0
  fi

  IFS=',' read -r -a wanted <<<"${parts_csv// /}"
  if [[ ${#wanted[@]} -eq 0 ]]; then
    log "SKIP ${domain}: no local-parts"
    return 0
  fi

  mkdir -p "$LOCK_ROOT"
  exec 200>"$lock"
  if command -v flock >/dev/null 2>&1; then
    if ! flock -w 30 200; then
      log "ERROR ${domain}: could not lock $lock"
      return 1
    fi
  else
    log "WARN ${domain}: flock unavailable; continuing without lock"
  fi

  if stat --version >/dev/null 2>&1; then
    owner="$(stat -c '%u:%g' "$aliases")"
    mode="$(stat -c '%a' "$aliases")"
  else
    owner="$(stat -f '%u:%g' "$aliases")"
    mode="$(stat -f '%Lp' "$aliases")"
  fi
  tmp="$(mktemp "${aliases}.XXXXXX")"

  # Keep non-managed lines; drop managed local-parts (we rewrite them).
  awk -v csv="$parts_csv" '
    BEGIN {
      n = split(csv, raw, /,/)
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", raw[i])
        if (raw[i] != "") skip[raw[i]] = 1
      }
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (match(line, /^([^:#]+):/)) {
        key = substr(line, RSTART, RLENGTH - 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
        if (key in skip) next
      }
      print line
    }
  ' "$aliases" >"$tmp"

  for part in "${wanted[@]}"; do
    [[ -n "$part" ]] || continue
    echo "${part}: ${PIPE_VALUE}" >>"$tmp"
  done

  if ! cmp -s "$aliases" "$tmp"; then
    cat "$tmp" >"$aliases"
    chown "$owner" "$aliases" 2>/dev/null || true
    chmod "$mode" "$aliases"
    log "FIXED ${domain}: restored pipe aliases for ${parts_csv}"
  else
    log "OK ${domain}: pipe aliases already correct"
  fi

  rm -f "$tmp"
  if command -v flock >/dev/null 2>&1; then
    flock -u 200 || true
  fi
  exec 200>&-
  return 0
}

main() {
  local filter_domain="${1:-}"
  local entry domain parts matched=0

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    domain="${entry%%|*}"
    parts="${entry#*|}"
    if [[ -n "$filter_domain" && "$domain" != "$filter_domain" ]]; then
      continue
    fi
    matched=1
    ensure_one "$domain" "$parts" || true
  done < <(parse_config)

  if [[ -n "$filter_domain" && "$matched" -eq 0 ]]; then
    log "SKIP ${filter_domain}: not listed in $CONFIG"
  fi
}

main "$@"
