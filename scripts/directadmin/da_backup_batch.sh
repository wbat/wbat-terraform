#!/bin/bash
# Run DirectAdmin admin backups one account at a time, so peak local disk usage is the
# largest single archive instead of the sum of all of them.
#
# Install: /usr/local/sbin/da-backup-batch.sh, driven by /etc/cron.d/da-backup-batch.
#
# Why this exists. DirectAdmin's scheduled admin backup archives every account before the
# all_backups_post hook gets a chance to upload anything, so it needs the whole set on
# local disk at once. The last full run that completed, on 2026-07-02, was 66 GiB. The
# root volume has had less free space than that ever since, and every daily run from then
# to 2026-09-07 logged "Running Backup" and produced no file at all -- two months with no
# account backups and nothing saying so. The engine is fine: a single-account run of the
# same command finishes in seconds and the hook uploads and clears it (verified on the
# primary 2026-09-07). It is the all-at-once staging that does not fit.
#
# So the unit of work here is one account. After each one the post-backup hook uploads it
# and deletes the local copy, and this script refuses to start the next account until it
# has confirmed that happened. Peak usage becomes the largest single archive, and an
# account that cannot fit is skipped and reported instead of filling the volume.
#
# Two independent guards, because the estimate is the part most likely to be wrong:
#
#   1. Before each account, require its estimated archive plus a reserve to fit in the
#      free space that exists right now.
#   2. During each account, watch free space and kill the backup if it crosses a floor.
#      An estimate derived from du cannot account for a database that grew, a compression
#      ratio that got worse, or another process writing to the same volume; the floor does
#      not care why the number moved.
#
# Paths are overridable by environment variable so prove_backup_batch.sh can exercise this
# without root, DirectAdmin, or S3.

set -uo pipefail
# Deliberately not `set -e`. A failure on one account must still produce a summary and an
# alert covering the others, and the abort paths below need to run their own cleanup.

DA_BIN="${DA_BATCH_DA_BIN:-/usr/local/directadmin/directadmin}"
USERS_DIR="${DA_BATCH_USERS_DIR:-/usr/local/directadmin/data/users}"
HOME_ROOT="${DA_BATCH_HOME:-/home}"
ADMIN_DIR="${DA_BACKUP_ADMIN_DIR:-/home/admin_backups}"
HOOK="${DA_BATCH_HOOK:-/usr/local/directadmin/scripts/custom/all_backups_post.sh}"
LOG="${DA_BATCH_LOG:-/var/log/da-backup-batch.log}"
LOCK="${DA_BATCH_LOCK:-/var/lock/da-backup-batch.lock}"

# Shared with the vhost-listen tooling and the backup hook so there is one address per
# host rather than three that can disagree.
CONFIG="${DA_BATCH_CONF:-/etc/da-vhost-listen/vhost-listen.conf}"
HEALTH_ALERT_TO=""

# Space that must still be free after the estimated archive is written. This is headroom
# for everything else on the box during the run, not slack in the estimate.
RESERVE_GB="${DA_BATCH_RESERVE_GB:-10}"
# Hard floor. If free space crosses this while an account is being archived, the backup is
# killed. Below this MySQL and Exim start failing writes, which is the outage this whole
# exercise is about avoiding.
FLOOR_GB="${DA_BATCH_FLOOR_GB:-8}"
# Estimated archive size as a percentage of the account's raw home directory size. 100 is
# deliberately pessimistic -- the 2026-07-02 run compressed 114 GB of homes into 66 GiB,
# so roughly 58% -- because being wrong in this direction skips an account, and being
# wrong in the other direction fills the volume.
SIZE_RATIO_PCT="${DA_BATCH_RATIO_PCT:-100}"
WATCH_INTERVAL_SEC="${DA_BATCH_WATCH_INTERVAL:-5}"
# How long to wait for the hook to drain the staging directory after an account finishes.
DRAIN_TIMEOUT_SEC="${DA_BATCH_DRAIN_TIMEOUT:-1800}"

HOST="$(hostname -s)"
MODE="run"
declare -a ONLY_USERS=()

usage() {
  sed -n '2,31p' "$0"
  cat <<'USAGE'

Usage:
  da-backup-batch.sh                  # back up every account, smallest first
  da-backup-batch.sh --user=teller    # only these accounts (repeatable)
  da-backup-batch.sh --list           # show accounts, sizes, and what would fit
  da-backup-batch.sh --dry-run        # plan the run without invoking DirectAdmin

Exit status is 0 only when every selected account was archived, uploaded and cleared.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) MODE=list; shift ;;
    --dry-run) MODE=dry-run; shift ;;
    --user=*)
      ONLY_USERS+=("${1#--user=}")
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() {
  local msg
  msg="$(date -Iseconds) $*"
  if [[ -w "$(dirname "$LOG")" ]] 2>/dev/null || [[ -w "$LOG" ]] 2>/dev/null; then
    echo "$msg" >>"$LOG" 2>/dev/null || true
  fi
  echo "$msg" >&2
}

if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

# Same guards as the backup hook: an address that can never receive mail is reported as
# broken alerting rather than logged as a successful send.
alert() {
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

  local mail_out mail_rc=0
  mail_out="$(printf '%s\n' "$body" | mail -s "$subject" "$dest" 2>&1)" || mail_rc=$?
  if ((mail_rc == 0)); then
    log "OK alert mailed to ${dest}"
  else
    log "ERROR alert submission FAILED (mail rc=${mail_rc}) to ${dest}: ${mail_out:-no output}"
  fi
}

avail_kb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4+0}'
}

gb() {
  awk -v k="$1" 'BEGIN { printf "%.1f", k/1048576 }'
}

# Accounts are directories under the DirectAdmin users tree that actually carry a
# user.conf. A plain glob also picks up whatever else has been left in there -- this host
# has a stray `fix.sh` -- and passing that to --user= makes DirectAdmin fail an entire
# batch on a name that was never an account.
list_users() {
  local d name
  for d in "$USERS_DIR"/*; do
    [[ -d "$d" && -f "${d}/user.conf" ]] || continue
    name="$(basename "$d")"
    if ((${#ONLY_USERS[@]} > 0)); then
      local wanted found=0
      for wanted in "${ONLY_USERS[@]}"; do
        [[ "$wanted" == "$name" ]] && found=1
      done
      ((found == 1)) || continue
    fi
    printf '%s\n' "$name"
  done
}

raw_kb_for() {
  local user="$1" kb
  kb="$(du -sk "${HOME_ROOT}/${user}" 2>/dev/null | cut -f1)"
  printf '%d' "${kb:-0}"
}

# Ascending, so a failure on the largest account leaves the other thirteen already safe in
# S3 rather than never attempted. On this host `teller` alone is roughly half the total.
ordered_users() {
  local u kb
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    kb="$(raw_kb_for "$u")"
    printf '%d\t%s\n' "$kb" "$u"
  done < <(list_users) | sort -n
}

staged_file_count() {
  find "$ADMIN_DIR" -type f 2>/dev/null | grep -c . || true
}

# The hook is what empties the staging directory, and it runs on DirectAdmin's event, not
# on this script's schedule. Starting the next account before it has finished is how a
# per-account run silently turns back into an all-at-once run.
wait_for_drain() {
  local waited=0 n
  while ((waited < DRAIN_TIMEOUT_SEC)); do
    n="$(staged_file_count)"
    n="${n:-0}"
    ((n == 0)) && return 0
    sleep "$WATCH_INTERVAL_SEC"
    waited=$((waited + WATCH_INTERVAL_SEC))
  done
  return 1
}

reserve_kb=$((RESERVE_GB * 1048576))
floor_kb=$((FLOOR_GB * 1048576))

declare -a done_users=() skipped_users=() failed_users=()
run_start_epoch="$(date +%s)"

# Runs one account under the free-space floor. The watchdog is a plain background loop
# rather than anything cleverer because it has to keep working when the volume is nearly
# full, which is when writing state files stops being reliable.
backup_one() {
  local user="$1"
  local abort_flag rc=0 da_pid watch_pid killed=0

  abort_flag="$(mktemp)" || {
    log "ERROR could not create the abort flag for ${user}; refusing to run without the free-space watchdog"
    return 1
  }
  : >"$abort_flag"

  # setsid so the backup gets its own process group. Without it, a non-interactive shell
  # puts the child in this script's group, and the group kill below would either miss or
  # -- worse -- signal this script. DirectAdmin forks tar and zstd, and killing only the
  # parent leaves those still writing into a volume that is already at the floor.
  if command -v setsid >/dev/null 2>&1; then
    setsid "$DA_BIN" admin-backup --destination="$ADMIN_DIR" --user="$user" >>"$LOG" 2>&1 &
  else
    "$DA_BIN" admin-backup --destination="$ADMIN_DIR" --user="$user" >>"$LOG" 2>&1 &
  fi
  da_pid=$!

  (
    while kill -0 "$da_pid" 2>/dev/null; do
      now_kb="$(avail_kb "$ADMIN_DIR")"
      now_kb="${now_kb:-0}"
      if ((now_kb < floor_kb)); then
        echo "$now_kb" >"$abort_flag"
        kill -TERM -- "-${da_pid}" 2>/dev/null || kill -TERM "$da_pid" 2>/dev/null
        break
      fi
      sleep "$WATCH_INTERVAL_SEC"
    done
  ) &
  watch_pid=$!

  wait "$da_pid" || rc=$?
  kill "$watch_pid" 2>/dev/null
  wait "$watch_pid" 2>/dev/null

  if [[ -s "$abort_flag" ]]; then
    killed=1
    log "ERROR killed the backup of ${user}: free space fell to $(gb "$(cat "$abort_flag")") GB, below the ${FLOOR_GB} GB floor"
  fi
  rm -f "$abort_flag"

  if ((killed == 1)); then
    # Whatever is in the staging directory now is a partial archive of this account. The
    # directory was confirmed empty before this account started, so there is nothing else
    # it could be, and leaving it would let the hook upload a truncated archive to S3 and
    # record it as a successful backup.
    local partial
    partial="$(find "$ADMIN_DIR" -type f 2>/dev/null)"
    if [[ -n "$partial" ]]; then
      log "removing the partial archive left by the killed run: $(printf '%s' "$partial" | tr '\n' ' ')"
      find "$ADMIN_DIR" -type f -delete 2>/dev/null
    fi
    return 1
  fi

  if ((rc != 0)); then
    log "ERROR admin-backup for ${user} exited ${rc}"
    return 1
  fi
  return 0
}

lock_fd=""
lock_dir="$(dirname "$LOCK")"
if [[ -d "$lock_dir" && -w "$lock_dir" ]] || [[ -w "$LOCK" ]]; then
  exec 9>"$LOCK" && lock_fd=9
fi
if [[ -n "$lock_fd" ]] && command -v flock >/dev/null 2>&1; then
  # Non-blocking: two batch runs overlapping would defeat the one-account-at-a-time
  # premise, and the second one has nothing useful to wait for.
  if ! flock -n 9; then
    log "another da-backup-batch run holds ${LOCK}; exiting"
    exit 0
  fi
fi

if [[ ! -d "$ADMIN_DIR" ]]; then
  log "ERROR staging directory ${ADMIN_DIR} does not exist"
  exit 1
fi

if [[ "$MODE" == "list" ]]; then
  printf '%-16s %10s %10s %s\n' "ACCOUNT" "HOME" "ESTIMATE" "FITS NOW"
  now_kb="$(avail_kb "$ADMIN_DIR")"
  now_kb="${now_kb:-0}"
  while IFS=$'\t' read -r kb user; do
    [[ -n "$user" ]] || continue
    est=$((kb * SIZE_RATIO_PCT / 100))
    if ((now_kb >= est + reserve_kb)); then fits="yes"; else fits="NO"; fi
    printf '%-16s %9sG %9sG %s\n' "$user" "$(gb "$kb")" "$(gb "$est")" "$fits"
  done < <(ordered_users)
  printf '\n%s GB free now; each account needs its estimate plus %s GB reserve.\n' \
    "$(gb "$now_kb")" "$RESERVE_GB"
  exit 0
fi

staged="$(staged_file_count)"
staged="${staged:-0}"
if ((staged > 0)); then
  # Someone else's archives, or the leftovers of a run whose upload failed. Adding to them
  # is precisely the all-at-once behaviour being avoided.
  log "ERROR ${ADMIN_DIR} already holds ${staged} file(s); not starting a batch on top of them"
  alert "DirectAdmin batch backup did not start on ${HOST}" \
    "${ADMIN_DIR} already contained ${staged} file(s) when the batch run began, so nothing was attempted.

Those are either an earlier run whose upload failed, or a backup someone started by hand.
Check ${LOG} and /var/log/da-backup-s3.log, then clear the directory or re-run the hook:
  ${HOOK}

Runbook: aws/docs/2026-09-06-primary-outage.md"
  exit 1
fi

limited_to=""
((${#ONLY_USERS[@]} > 0)) && limited_to=", limited to ${ONLY_USERS[*]}"
log "start ${HOST}: $(gb "$(avail_kb "$ADMIN_DIR")") GB free, reserve ${RESERVE_GB} GB, floor ${FLOOR_GB} GB${limited_to}"

aborted=""
while IFS=$'\t' read -r kb user; do
  [[ -n "$user" ]] || continue
  [[ -n "$aborted" ]] && break

  est_kb=$((kb * SIZE_RATIO_PCT / 100))
  now_kb="$(avail_kb "$ADMIN_DIR")"
  now_kb="${now_kb:-0}"

  # Check the floor before starting rather than letting the watchdog discover it. Starting
  # a backup on a volume that is already below the floor means killing it a second later,
  # which reads in the log as a backup that failed rather than one that was never viable,
  # and leaves a partial archive to clean up for no reason.
  if ((now_kb < floor_kb)); then
    log "SKIP ${user}: only $(gb "$now_kb") GB free, already below the ${FLOOR_GB} GB floor; nothing will be attempted until space is recovered"
    skipped_users+=("${user} (only $(gb "$now_kb") GB free, below the ${FLOOR_GB} GB floor)")
    continue
  fi

  if ((now_kb < est_kb + reserve_kb)); then
    log "SKIP ${user}: needs about $(gb "$est_kb") GB plus a ${RESERVE_GB} GB reserve, and only $(gb "$now_kb") GB is free"
    skipped_users+=("${user} (estimate $(gb "$est_kb") GB, free $(gb "$now_kb") GB)")
    continue
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    log "would back up ${user} (home $(gb "$kb") GB, estimate $(gb "$est_kb") GB, free $(gb "$now_kb") GB)"
    done_users+=("$user")
    continue
  fi

  log "backing up ${user} (home $(gb "$kb") GB, estimate $(gb "$est_kb") GB, free $(gb "$now_kb") GB)"
  if ! backup_one "$user"; then
    failed_users+=("$user")
    # A kill or a DirectAdmin failure on one account says nothing reliable about the next,
    # except when it was the floor that fired -- and in that case continuing is how the
    # volume fills. Stop and let a person look.
    aborted="${user}"
    break
  fi

  if ! wait_for_drain; then
    log "ERROR ${ADMIN_DIR} still holds $(staged_file_count) file(s) ${DRAIN_TIMEOUT_SEC}s after ${user} finished; the upload hook has not cleared it"
    failed_users+=("${user} (archived but not uploaded and cleared)")
    aborted="${user}"
    break
  fi

  log "OK ${user} archived, uploaded and cleared ($(gb "$(avail_kb "$ADMIN_DIR")") GB free)"
  done_users+=("$user")
done < <(ordered_users)

elapsed=$(($(date +%s) - run_start_epoch))
log "finished in ${elapsed}s: ${#done_users[@]} done, ${#skipped_users[@]} skipped, ${#failed_users[@]} failed ($(gb "$(avail_kb "$ADMIN_DIR")") GB free)"

if ((${#failed_users[@]} == 0 && ${#skipped_users[@]} == 0)); then
  exit 0
fi

detail=""
if ((${#failed_users[@]} > 0)); then
  detail+="Failed:
$(printf '  - %s\n' "${failed_users[@]}")
"
fi
if ((${#skipped_users[@]} > 0)); then
  detail+="Skipped for lack of space -- these accounts have no current backup:
$(printf '  - %s\n' "${skipped_users[@]}")
"
fi
if [[ -n "$aborted" ]]; then
  detail+="
The run stopped at ${aborted}, so any account after it in size order was not attempted.
"
fi

alert "DirectAdmin batch backup incomplete on ${HOST} ($(gb "$(avail_kb "$ADMIN_DIR")") GB free)" \
  "${#done_users[@]} account(s) were backed up and uploaded. The rest were not.

${detail}
An account that is skipped every night has no backup at all, which is the condition this
script exists to make visible rather than silent. If the largest account no longer fits,
the options are to give the staging directory its own volume or to shrink the account.

Disk: $(df -Ph "$ADMIN_DIR" 2>/dev/null | awk 'NR==2 {printf "%s used, %s free", $5, $4}')
Recent log:
$(tail -20 "$LOG" 2>/dev/null | sed 's/^/  /')

Runbook: aws/docs/2026-09-06-primary-outage.md"

exit 1
