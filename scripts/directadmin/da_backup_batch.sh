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
# When the current lock holder started, recorded beside the lock rather than inside it:
# opening the lock file truncates it, so a run that loses the race would erase the very
# record it needs to read.
LOCK_STARTED="${LOCK}.started"
# How long a holder may keep the lock before the run that finds it says so out loud.
# Exiting quietly is right for two runs a few minutes apart and wrong for a holder that
# has been stuck since yesterday -- that branch is how one hung run turns into weeks of no
# backups. A day means the daily schedule has already missed a night, which is the point
# at which a person should hear about it rather than read about it later.
STALE_LOCK_SEC="${DA_BATCH_STALE_LOCK_SEC:-86400}"

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
# Hard limit on one account's archive run.
#
# The free-space floor only fires when the volume is filling. A backup can hang without
# consuming a single byte -- an rclone inside the upload hook that stops making progress
# against S3, DirectAdmin waiting on a MySQL lock, a filesystem that stops answering --
# and a bare `wait` on the child is unbounded. That run never reaches the summary and
# never mails, and because it still holds the batch lock, every cron invocation after it
# takes the "another run holds it" branch and exits 0. Account backups would stop
# completely, for as long as the hang lasts, with nothing saying so: the same
# silent-failure shape as the two months this script exists to end.
#
# Six hours is far longer than any account on this host has plausibly needed -- the whole
# 2026-07-02 run of all fourteen accounts produced 66 GiB well inside that -- and short
# enough that the next daily run at 01:00 finds the lock free.
ACCOUNT_TIMEOUT_SEC="${DA_BATCH_ACCOUNT_TIMEOUT:-21600}"
# Grace between TERM and KILL when a backup is being stopped. tar and zstd exit promptly
# on TERM; a process that does not is precisely the one that must not be left running,
# because both reasons for stopping it -- the floor and the timeout -- get worse the
# longer it keeps writing.
KILL_GRACE_SEC="${DA_BATCH_KILL_GRACE:-60}"

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
# Why the last backup_one call gave up, in words the summary mail can use. A failure that
# reads only as the account name tells whoever opens the mail nothing about whether to
# free disk or to go looking for a stuck rclone.
backup_one_reason=""

# Stop a backup and everything DirectAdmin forked from it. TERM first, then KILL, because
# a TERM that is ignored is indistinguishable from one that worked right up until the
# volume is full -- and the two callers of this are the floor breach and the per-account
# timeout, neither of which can afford to be wrong about whether the writing stopped.
stop_group() {
  local pid="$1" waited=0
  kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  while ((waited < KILL_GRACE_SEC)) && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done
  # Unconditionally, not only while the parent is still alive. DirectAdmin forks tar and
  # zstd; a parent that exits cleanly on TERM can leave those behind still writing into
  # the volume this is trying to protect. If the group is already gone this is a no-op.
  kill -KILL -- "-${pid}" 2>/dev/null || true
}

# Runs one account under the free-space floor and the per-account time limit. The watchdog
# is a plain background loop rather than anything cleverer because it has to keep working
# when the volume is nearly full, which is when writing state files stops being reliable.
backup_one() {
  local user="$1"
  local abort_flag rc=0 da_pid watch_pid killed=0
  local abort_reason="" abort_detail=""
  backup_one_reason=""

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

  # One watchdog for both bounds. It samples on the same tick, so the elapsed count is
  # the loop's own, not a second timer that could disagree with it.
  (
    watched=0
    while kill -0 "$da_pid" 2>/dev/null; do
      now_kb="$(avail_kb "$ADMIN_DIR")"
      now_kb="${now_kb:-0}"
      if ((now_kb < floor_kb)); then
        printf 'floor %s\n' "$now_kb" >"$abort_flag"
        break
      fi
      if ((ACCOUNT_TIMEOUT_SEC > 0 && watched >= ACCOUNT_TIMEOUT_SEC)); then
        printf 'timeout %s\n' "$watched" >"$abort_flag"
        break
      fi
      sleep "$WATCH_INTERVAL_SEC"
      watched=$((watched + WATCH_INTERVAL_SEC))
    done
    # The loop also ends when the backup finishes on its own, which is the common case and
    # needs no signal at all.
    [[ -s "$abort_flag" ]] || exit 0
    stop_group "$da_pid"
  ) &
  watch_pid=$!

  wait "$da_pid" || rc=$?
  if [[ -s "$abort_flag" ]]; then
    # The watchdog is part-way through escalating TERM to KILL. Tearing it down here is how
    # the tar DirectAdmin forked outlives the kill that was meant for its whole group, and
    # keeps writing into a volume that is already at the floor.
    wait "$watch_pid" 2>/dev/null
  else
    kill "$watch_pid" 2>/dev/null
    wait "$watch_pid" 2>/dev/null
  fi

  if [[ -s "$abort_flag" ]]; then
    killed=1
    read -r abort_reason abort_detail <"$abort_flag"
    case "$abort_reason" in
      timeout)
        backup_one_reason="killed after ${abort_detail}s, past the ${ACCOUNT_TIMEOUT_SEC}s per-account limit"
        log "ERROR killed the backup of ${user}: still running after ${abort_detail}s, past the ${ACCOUNT_TIMEOUT_SEC}s per-account limit. Free space never moved, so this is a hang rather than a full volume -- look for a stalled rclone in the upload hook before the next run."
        ;;
      *)
        backup_one_reason="killed at the ${FLOOR_GB} GB free-space floor"
        log "ERROR killed the backup of ${user}: free space fell to $(gb "$abort_detail") GB, below the ${FLOOR_GB} GB floor"
        ;;
    esac
  fi
  rm -f "$abort_flag"

  if ((killed == 1)); then
    # Whatever is in the staging directory now belongs to this account: the directory was
    # confirmed empty before it started, so there is nothing else it could be. It is
    # deleted rather than left for the hook because a killed run cannot say whether the
    # archive is truncated, and an archive of unknown completeness is a truncated one as
    # far as S3 is concerned -- uploading it would record a partial backup as a successful
    # one. Losing a re-creatable archive is the cheap side of that trade.
    local partial
    partial="$(find "$ADMIN_DIR" -type f 2>/dev/null)"
    if [[ -n "$partial" ]]; then
      log "removing the partial archive left by the killed run: $(printf '%s' "$partial" | tr '\n' ' ')"
      find "$ADMIN_DIR" -type f -delete 2>/dev/null
    fi
    return 1
  fi

  if ((rc != 0)); then
    backup_one_reason="admin-backup exited ${rc}"
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
# Whether the run holding the lock has been there long enough to be a fault rather than an
# overlap. Only a real backup run reports it: someone running --list to find out what is
# going on should not generate the mail they are already investigating.
stale_lock_holder() {
  local held_for="$1"
  [[ "$MODE" == "run" ]] || return 1
  [[ "$held_for" =~ ^[0-9]+$ ]] || return 1
  ((held_for > STALE_LOCK_SEC))
}

if [[ -n "$lock_fd" ]] && command -v flock >/dev/null 2>&1; then
  # Non-blocking: two batch runs overlapping would defeat the one-account-at-a-time
  # premise, and the second one has nothing useful to wait for.
  if ! flock -n 9; then
    held_since=""
    held_for=""
    [[ -s "$LOCK_STARTED" ]] && held_since="$(head -1 "$LOCK_STARTED" 2>/dev/null)"
    [[ "$held_since" =~ ^[0-9]+$ ]] && held_for=$(($(date +%s) - held_since))

    # Skipping quietly is correct for an overlap of minutes and catastrophic if the holder
    # never lets go: nothing else in this script runs, so the daily schedule reports
    # success every night while no account is backed up. The per-account limit above is
    # what should prevent a holder ever getting this old; if one does anyway, that is a
    # failure of the thing meant to catch failures, and it has to reach a person.
    if stale_lock_holder "$held_for"; then
      log "ERROR another da-backup-batch run has held ${LOCK} for ${held_for}s; no account was backed up by this run"
      alert "DirectAdmin batch backup has been stuck for ${held_for}s on ${HOST}" \
        "A da-backup-batch run took ${LOCK} ${held_for}s ago and has not released it, so this run backed up nothing and neither did any run since.

No account on ${HOST} has been backed up for at least that long.

Find the holder and decide whether it is working or wedged:
  ps -eo pid,etime,cmd | grep -e da-backup-batch -e admin-backup
  pgrep -a rclone
  tail -50 ${LOG}
  tail -50 /var/log/da-backup-s3.log

Each account is bounded by a ${ACCOUNT_TIMEOUT_SEC}s limit, so a holder older than that is
stuck somewhere the limit does not cover -- most likely waiting on the upload hook to
clear ${ADMIN_DIR}.

Runbook: aws/docs/2026-09-06-primary-outage.md"
      exit 1
    fi

    log "another da-backup-batch run holds ${LOCK}${held_for:+ (started ${held_for}s ago)}; exiting"
    exit 0
  fi

  # Written only by whoever holds the lock, and only once it is held, so the value a later
  # run reads is always the current holder's start time.
  printf '%s\n' "$(date +%s)" >"$LOCK_STARTED" 2>/dev/null \
    || log "WARN could not record the start time in ${LOCK_STARTED}; a later run will not be able to tell a stuck holder from a brief overlap"
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
    failed_users+=("${user}${backup_one_reason:+ (${backup_one_reason})}")
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
