#!/bin/bash
# Health check for SES Gmail pipe path. Cron every 5 minutes.
# Alerts by logging + optional mail if HEALTH_ALERT_TO is set in
# /etc/ses-gmail-forward/health.conf
#
# Install:
#   install -m 755 ses_gmail_forward_health.sh /usr/local/bin/ses-gmail-forward-health.sh
#   echo '*/5 * * * * root /usr/local/bin/ses-gmail-forward-health.sh' \
#     >/etc/cron.d/ses-gmail-forward-health

set -euo pipefail

CONF="${SES_GMAIL_HEALTH_CONF:-/etc/ses-gmail-forward/health.conf}"
LOG="${SES_GMAIL_HEALTH_LOG:-/var/log/ses-gmail-forward-health.log}"
FORWARD_LOG="${SES_GMAIL_FORWARD_LOG:-/var/log/ses-gmail-forward.log}"
SCRIPT="${SES_GMAIL_FORWARD_SCRIPT:-/usr/local/bin/ses-gmail-forward.py}"
ALIASES_ENSURE="${ENSURE_SES_GMAIL_ALIASES:-/usr/local/bin/ensure-ses-gmail-aliases.sh}"
STATE_DIR="${SES_GMAIL_HEALTH_STATE:-/var/lib/ses-gmail-forward}"
ALERT_STAMP="${STATE_DIR}/health-alert.stamp"
WINDOW_MINUTES="${SES_GMAIL_HEALTH_WINDOW_MINUTES:-15}"

HEALTH_ALERT_TO=""
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi

log() {
  echo "$(date -Iseconds) $*" >>"$LOG" 2>/dev/null || true
}

fail=0
reasons=()

# 1) Script present + executable
if [[ ! -x "$SCRIPT" ]]; then
  fail=1
  reasons+=("missing_or_not_executable:$SCRIPT")
fi

# 2) python + boto3
if ! python3 -c 'import boto3' >/dev/null 2>&1; then
  fail=1
  reasons+=("boto3_missing")
fi

# 3) Enforce aliases (self-heal)
if [[ -x "$ALIASES_ENSURE" ]]; then
  "$ALIASES_ENSURE" >/dev/null 2>&1 || {
    fail=1
    reasons+=("alias_ensure_failed")
  }
fi

# 4) Recent ERROR / silent-skip lines in forward log (pipe failures / SES)
if [[ -f "$FORWARD_LOG" ]]; then
  # GNU find -mmin on the log isn't enough; scan recent lines by timestamp prefix.
  cutoff="$(date -d "-${WINDOW_MINUTES} minutes" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-"${WINDOW_MINUTES}"M '+%Y-%m-%d %H:%M:%S')"
  # shellcheck disable=SC2016
  recent_bad="$(awk -v c="$cutoff" '
    {
      ts = substr($0, 1, 19)
      if (ts < c) next
      # Obsolete path: lda under pipe as user mail (fixed; ignore historical noise)
      if ($0 ~ /dovecot-lda failed/) next
      if ($0 ~ / ERROR /) { print; next }
      # Structured skips that mean Gmail never got a copy (alert-worthy)
      if ($0 ~ /skip_ses reason=(rate_limit|ses_error|config_error|missing_gmail_dest)/) { print; next }
      if ($0 ~ /Rate limit exceeded/) { print; next }
      if ($0 ~ /SES SendRawEmail failed/) { print; next }
      if ($0 ~ /gmail_destination missing/) { print; next }
      if ($0 ~ /Failed to load runtime config/) { print; next }
    }
  ' "$FORWARD_LOG" | tail -20)"
  if [[ -n "$recent_bad" ]]; then
    fail=1
    reasons+=("recent_forward_errors_or_skips")
    log "RECENT_BAD:"$'\n'"$recent_bad"
  fi
fi

# 5) Managed aliases still pipe-only (quick grep if config exists)
MANAGED="${SES_GMAIL_ALIASES_CONF:-/etc/ses-gmail-forward/managed-aliases.conf}"
if [[ -f "$MANAGED" ]]; then
  while read -r domain parts; do
    [[ -z "${domain:-}" || "$domain" =~ ^# ]] && continue
    aliases="/etc/virtual/${domain}/aliases"
    [[ -f "$aliases" ]] || continue
    IFS=',' read -r -a lps <<<"${parts// /}"
    for lp in "${lps[@]}"; do
      [[ -z "$lp" ]] && continue
      line="$(grep -E "^${lp}:" "$aliases" 2>/dev/null || true)"
      if [[ "$line" != *'|/usr/local/bin/ses-gmail-forward.py'* ]]; then
        fail=1
        reasons+=("bad_alias:${domain}:${lp}")
      fi
    done
  done < <(grep -vE '^\s*(#|$)' "$MANAGED" || true)
fi

mkdir -p "$STATE_DIR"

if [[ "$fail" -eq 0 ]]; then
  log "OK"
  rm -f "$ALERT_STAMP"
  exit 0
fi

msg="ses-gmail-forward HEALTH FAIL: ${reasons[*]}"
log "$msg"

# Rate-limit alerts to once per hour
now_epoch="$(date +%s)"
if [[ -f "$ALERT_STAMP" ]]; then
  last="$(cat "$ALERT_STAMP" 2>/dev/null || echo 0)"
  if (( now_epoch - last < 3600 )); then
    exit 1
  fi
fi
echo "$now_epoch" >"$ALERT_STAMP"

if [[ -n "$HEALTH_ALERT_TO" ]]; then
  printf '%s\n' "$msg" "See $FORWARD_LOG and $LOG" \
    | mail -s "ses-gmail-forward health FAIL on $(hostname -s)" "$HEALTH_ALERT_TO" 2>/dev/null || true
fi

exit 1
