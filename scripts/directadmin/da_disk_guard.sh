#!/bin/bash
# Alert while the disk is merely filling up, instead of after it is full.
#
# On 2026-09-06 the primary ran out of root disk and services fell over. Nothing in this
# account watches disk: the only CloudWatch alarms are on billing, and EC2 publishes no
# filesystem metric without the CloudWatch agent, which is not installed on these hosts.
# So the first signal was the outage itself. This script is the cheap version of that
# missing alarm -- cron, df, and the same local MTA the rest of the DA tooling uses.
#
# Install:
#   install -m 755 da_disk_guard.sh /usr/local/sbin/da-disk-guard.sh
#   # driven by the hourly entry in /etc/cron.d/da-disk-guard
#
# Usage:
#   da-disk-guard.sh            # check, log, alert when over threshold
#   da-disk-guard.sh --report   # print the report and never alert
#
# Exits non-zero when a filesystem is over its threshold, so it is also usable as a
# one-off health check.

set -uo pipefail

CONFIG="${DA_DISK_GUARD_CONF:-/etc/da-vhost-listen/vhost-listen.conf}"
LOG="${DA_DISK_GUARD_LOG:-/var/log/da-disk-guard.log}"
STATE_DIR="${DA_DISK_GUARD_STATE:-/var/lib/da-disk-guard}"
ALERT_STAMP="${STATE_DIR}/alert.stamp"
# Six hours: long enough not to mail hourly about a disk nobody has had time to clear,
# short enough that a filling volume is raised again the same day.
ALERT_COOLDOWN_SEC="${DA_DISK_GUARD_ALERT_COOLDOWN:-21600}"

# Space and inodes both end in "no space left on device"; df -h shows only the first.
# A backup run that leaves hundreds of thousands of small files can exhaust inodes on a
# volume that still reports free gigabytes.
WARN_PCT="${DA_DISK_GUARD_WARN_PCT:-85}"
CRIT_PCT="${DA_DISK_GUARD_CRIT_PCT:-92}"
INODE_PCT="${DA_DISK_GUARD_INODE_PCT:-85}"
WATCH_PATHS="${DA_DISK_GUARD_PATHS:-/ /home}"

HEALTH_ALERT_TO=""
MODE="check"

log() {
  local msg
  msg="$(date -Iseconds) disk-guard: $*"
  if [[ -w "$(dirname "$LOG")" ]] 2>/dev/null || [[ -w "$LOG" ]] 2>/dev/null; then
    echo "$msg" >>"$LOG" 2>/dev/null || true
  fi
  echo "$msg" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)
      MODE=report
      shift
      ;;
    -h | --help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

# Same destination guards as the reconciler: an address that can never receive mail is
# logged as broken alerting, not as a successful send.
rate_limited_alert() {
  local subject="$1" body="$2"
  local dest="${HEALTH_ALERT_TO}"
  local dest_lc="${dest,,}"

  if [[ -z "$dest" ]]; then
    log "ERROR alert not sent (HEALTH_ALERT_TO unset in ${CONFIG}): $subject"
    return 0
  fi
  if [[ "$dest_lc" =~ @([a-z0-9-]+\.)*(example\.(com|net|org)|example|invalid|test|localhost)$ ]]; then
    log "ERROR alert not sent (HEALTH_ALERT_TO=${dest} is a reserved placeholder; set a real address in ${CONFIG}): $subject"
    return 0
  fi
  if ! command -v mail >/dev/null 2>&1; then
    log "ERROR alert not sent (no mail binary; install s-nail or mailx): $subject"
    return 0
  fi

  mkdir -p "$STATE_DIR" 2>/dev/null
  local now last=0
  now="$(date +%s)"
  [[ -f "$ALERT_STAMP" ]] && last="$(cat "$ALERT_STAMP" 2>/dev/null || echo 0)"
  if ((now - last < ALERT_COOLDOWN_SEC)); then
    log "SKIP alert cooldown (${ALERT_COOLDOWN_SEC}s)"
    return 0
  fi
  echo "$now" >"$ALERT_STAMP" 2>/dev/null

  local mail_out mail_rc=0
  mail_out="$(printf '%s\n' "$body" | mail -s "$subject" "$dest" 2>&1)" || mail_rc=$?
  if ((mail_rc == 0)); then
    log "OK alert mailed to ${dest}"
  else
    # A send that never landed must not buy six hours of silence about a filling disk.
    rm -f "$ALERT_STAMP" 2>/dev/null
    log "ERROR alert submission FAILED (mail rc=${mail_rc}) to ${dest}: ${mail_out:-no output}"
  fi
}

host="$(hostname -f 2>/dev/null || hostname)"
findings=()
worst=0
seen_devices=""

for path in $WATCH_PATHS; do
  [[ -d "$path" ]] || continue

  read -r device mount used_pct avail_h < <(
    df -Pk "$path" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); printf "%s %s %d %.1f\n", $1, $6, $5, $4/1048576}'
  )
  [[ -n "${device:-}" ]] || continue

  # / and /home are the same volume on these hosts. Report the filesystem once rather
  # than mailing the same number twice under two names.
  case " ${seen_devices} " in
    *" ${device} "*) continue ;;
  esac
  seen_devices="${seen_devices} ${device}"

  inode_pct="$(df -Pi "$path" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}')"
  inode_pct="${inode_pct:-0}"

  log "${mount} (${device}) ${used_pct}% used, ${avail_h} GB free, inodes ${inode_pct}%"
  ((used_pct > worst)) && worst="$used_pct"

  if ((used_pct >= CRIT_PCT)); then
    findings+=("CRITICAL ${mount} is ${used_pct}% used (${avail_h} GB free); threshold ${CRIT_PCT}%")
  elif ((used_pct >= WARN_PCT)); then
    findings+=("WARNING ${mount} is ${used_pct}% used (${avail_h} GB free); threshold ${WARN_PCT}%")
  fi
  if ((inode_pct >= INODE_PCT)); then
    findings+=("WARNING ${mount} has used ${inode_pct}% of its inodes; a volume can hit ENOSPC with free space left")
  fi
done

if ((${#findings[@]} == 0)); then
  log "OK all watched filesystems below thresholds (worst ${worst}%)"
  exit 0
fi

# Backups first: they are both the largest thing on this volume and the usual cause, so
# an operator reading the mail on a phone can tell straight away whether the backup hook
# failed to clean up or the space went somewhere else.
detail="$(
  printf '%s\n' "${findings[@]}"
  echo
  echo "Local backup directories:"
  du -sh /home/admin_backups /home/backup 2>/dev/null | sed 's/^/  /'
  echo
  echo "Largest directories under / (same filesystem only):"
  du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -15 | sed 's/^/  /'
  echo
  echo "Last backup upload attempt:"
  tail -10 /var/log/da-backup-s3.log 2>/dev/null | sed 's/^/  /'
)"

log "ERROR ${#findings[@]} finding(s); worst ${worst}% used"
while IFS= read -r line; do
  [[ -n "$line" ]] && log "  $line"
done <<<"$detail"

if [[ "$MODE" == "report" ]]; then
  printf '%s\n' "$detail"
  exit 1
fi

rate_limited_alert "Disk ${worst}% used on ${host}" \
  "${host} is running low on disk. At 100% MySQL, Exim and nginx start failing writes, which is what took the server down on 2026-09-06.

${detail}

First checks:
  tail -50 /var/log/da-backup-s3.log        # did the backup upload fail?
  /usr/local/directadmin/scripts/custom/all_backups_post.sh   # retry upload + cleanup

Runbook: aws/docs/disk-full-backup-incident.md"

exit 1
