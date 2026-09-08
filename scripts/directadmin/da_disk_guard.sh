#!/bin/bash
# Alert while a resource is merely running out, instead of after it has run out.
#
# Nothing in this account watches disk or memory: the only CloudWatch alarms are on
# billing, and EC2 publishes neither a filesystem nor a memory metric without the
# CloudWatch agent, which is not installed on these hosts. So on 2026-09-06 the first
# signal was the outage itself. This script is the cheap version of those missing alarms
# -- cron, df, /proc, and the same local MTA the rest of the DA tooling uses.
#
# Memory is checked as well as disk, because memory is what actually killed the primary:
# a nightly job drove committed memory to 9.6 GB on a 3.8 GB host and it thrashed for
# five hours. Two consequences for the design:
#
#   - An hourly check cannot see a ten-minute collapse, and a thrashing box cannot run
#     cron anyway. So the overnight *peak* is read back out of sar's history, which
#     survives the event. That is the check that would have caught this one: nightly
#     swap peaks climbed 64% -> 81% -> 97% over the week before the host died.
#   - Committed memory is watched, not just used memory. %commit went from 52% to 118%
#     -- the kernel had promised more than RAM and swap combined -- while %memused only
#     read 82%, which on its own looks survivable.
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

# Swap peaked at 64% on the first quiet night of the week that ended in the outage, so
# 60% is the line that gives a week of warning rather than an hour. Commit above 100%
# means more memory has been promised than physically exists; 95% is the last point at
# which that is still a warning rather than a fact.
SWAP_PCT="${DA_DISK_GUARD_SWAP_PCT:-60}"
COMMIT_PCT="${DA_DISK_GUARD_COMMIT_PCT:-95}"

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

##############################################################################
# Memory
##############################################################################
meminfo_kb() { awk -v k="$1:" '$1 == k {print $2; exit}' /proc/meminfo 2>/dev/null; }

pct_of() { # used total -> integer percent, 0 when total is 0
  awk -v u="$1" -v t="$2" 'BEGIN {print (t > 0) ? int((u * 100) / t) : 0}'
}

# Highest %swpused recorded in today's sar file. The column is located by name rather
# than position so this does not break if sar's layout or locale shifts.
sar_swap_peak() {
  command -v sar >/dev/null 2>&1 || return 1
  local f="/var/log/sa/sa$(date +%d)"
  [[ -r "$f" ]] || return 1
  LC_ALL=C sar -S -f "$f" 2>/dev/null | awk '
    /%swpused/ { for (i = 1; i <= NF; i++) if ($i == "%swpused") col = i; next }
    col && $1 ~ /^[0-9]/ && $col + 0 > max { max = $col + 0; at = $1 }
    END { if (max > 0) printf "%d %s\n", max, at }
  '
}

mem_total="$(meminfo_kb MemTotal)"
if [[ -n "${mem_total:-}" ]] && ((mem_total > 0)); then
  swap_total="$(meminfo_kb SwapTotal)"
  swap_free="$(meminfo_kb SwapFree)"
  committed="$(meminfo_kb Committed_AS)"
  swap_total="${swap_total:-0}"
  swap_free="${swap_free:-0}"
  committed="${committed:-0}"

  swap_used_pct="$(pct_of "$((swap_total - swap_free))" "$swap_total")"
  commit_pct="$(pct_of "$committed" "$((mem_total + swap_total))")"

  log "memory: swap ${swap_used_pct}% used, committed ${commit_pct}% of RAM+swap"

  if ((commit_pct >= COMMIT_PCT)); then
    findings+=("CRITICAL committed memory is ${commit_pct}% of RAM+swap; above 100% the kernel has promised memory that does not exist")
  fi
  if ((swap_used_pct >= SWAP_PCT)); then
    findings+=("WARNING swap is ${swap_used_pct}% used right now; threshold ${SWAP_PCT}%")
  fi

  # The peak matters more than the instant: this host is idle by the time anyone reads
  # the mail, and the dangerous window is ten minutes long.
  if read -r peak_pct peak_at < <(sar_swap_peak); then
    log "memory: peak swap today ${peak_pct}% at ${peak_at}"
    if ((peak_pct >= SWAP_PCT)) && ((swap_used_pct < SWAP_PCT)); then
      findings+=("WARNING swap reached ${peak_pct}% at ${peak_at} today and has since receded; the host is one bad night from thrashing (threshold ${SWAP_PCT}%)")
    fi
  fi
fi

if ((${#findings[@]} == 0)); then
  log "OK disk and memory below thresholds (worst filesystem ${worst}%)"
  exit 0
fi

# Backups first: they are both the largest thing on this volume and the usual cause, so
# an operator reading the mail on a phone can tell straight away whether the backup hook
# failed to clean up or the space went somewhere else.
detail="$(
  printf '%s\n' "${findings[@]}"
  echo
  echo "Memory:"
  free -m 2>/dev/null | sed 's/^/  /'
  echo
  echo "Largest resident processes:"
  ps -eo rss,pid,user,args --sort=-rss 2>/dev/null | head -8 |
    awk 'NR==1 {print "  " $0; next} {printf "  %.0f MB  pid %s  %s  %s\n", $1/1024, $2, $3, substr($0, index($0,$4), 80)}'
  echo
  echo "Local backup directories:"
  du -sh /home/admin_backups /home/backup /backup 2>/dev/null | sed 's/^/  /'
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

# Name the resource that fired. "Disk 99% used" on a memory alert is how an operator
# learns to ignore these.
subject="Resource pressure on ${host}"
if printf '%s\n' "${findings[@]}" | grep -q 'memory\|swap'; then
  if ((worst >= WARN_PCT)); then
    subject="Memory pressure and disk ${worst}% used on ${host}"
  else
    subject="Memory pressure on ${host}"
  fi
elif ((worst > 0)); then
  subject="Disk ${worst}% used on ${host}"
fi

rate_limited_alert "$subject" \
  "${host} is running low on a resource it cannot recover from unaided.

Memory is the one that has already caused an outage here: on 2026-09-06 a nightly cron
job drove committed memory past RAM+swap and the host thrashed for five hours until it
was rebooted. Disk has not caused an outage, but at 100% MySQL, Exim and nginx all start
failing writes.

${detail}

First checks:
  sar -r -f /var/log/sa/sa\$(date +%d)      # memory through the day
  sar -S -f /var/log/sa/sa\$(date +%d)      # swap; look for a spike, not a plateau
  tail -50 /var/log/da-backup-s3.log        # did the backup upload fail?

Runbook: aws/docs/2026-09-06-primary-outage.md"

exit 1
