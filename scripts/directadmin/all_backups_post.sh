#!/bin/bash
# DirectAdmin post-backup hook: upload admin + system backups to S3, then free local disk.
#
# Install: /usr/local/directadmin/scripts/custom/all_backups_post.sh
# system_backup_post.sh execs this file, so system backups run the same path.
#
# This hook is the only thing that stops the local backup directories growing without
# bound on a 200 GB root volume. It had four ways to skip that cleanup while still
# logging success (see aws/docs/2026-09-06-primary-outage.md):
#
#   1. `set -e` aborted the run as soon as an rclone upload returned non-zero, and both
#      cleanup steps came after both uploads. One transient S3 error left every local
#      archive in place, and the next backup added a fresh set on top of it.
#   2. Cleanup recomputed `date +%m-%d-%y` rather than reusing the directory the upload
#      had resolved. Whenever the two disagreed -- hook firing after midnight, or upload
#      falling back to the newest directory because today's did not exist -- cleanup
#      deleted nothing, logged "cleaned local system backup dirs", and exited 0.
#   3. SYSTEM_ROOT was hardcoded to a path that holds nothing on the host that matters.
#      This is the one that actually fired on the primary, and it is indistinguishable
#      from (2) in the log: both print a cleanup line after deleting nothing.
#   4. Nothing alerted, so any of the above was invisible until the disk was full.
#
# The rules now: resolve every path once, confirm the objects are in S3 before deleting
# the local copy, run each cleanup independently of the other upload's outcome, and mail
# HEALTH_ALERT_TO whenever a run ends with backups still on disk.
#
# Deleting a backup is irreversible, so nothing here removes a local file it has not just
# confirmed in S3 -- including the age-based sweep, where "old" is not evidence of "safe".
#
# Paths are overridable by environment variable so prove_backup_cleanup.sh can exercise
# this without root, S3, or DirectAdmin.

set -uo pipefail
# Deliberately NOT `set -e`. This script exists to free disk space, and the failure that
# filled the disk was an early exit that jumped over the cleanup. Every fallible command
# below captures its own exit status instead.

ADMIN_DIR="${DA_BACKUP_ADMIN_DIR:-/home/admin_backups}"
# DirectAdmin does not put system backups in the same place on every build: the primary
# writes them to /backup, while the hook installed there had /home/backup hardcoded. That
# directory exists and is empty, so for two months the hook logged "cleaned local system
# backup dirs under /home/backup" after doing nothing at all, while /backup grew to 59 GB
# of weekly archives. A hardcoded root fails silently and looks healthy; detect it.
SYSTEM_ROOT="${DA_BACKUP_SYSTEM_ROOT:-}"
SYSTEM_ROOT_CANDIDATES="${DA_BACKUP_SYSTEM_ROOTS:-/backup /home/backup}"
BUCKET="${DA_BACKUP_BUCKET:-wbat-tellerstech-directadmin-backups-708113892725}"
REMOTE="${DA_BACKUP_REMOTE:-s3backup}"
LOG="${DA_BACKUP_LOG:-/var/log/da-backup-s3.log}"
LOCK="${DA_BACKUP_LOCK:-/var/lock/da-backup-s3.lock}"
LOCK_WAIT_SEC="${DA_BACKUP_LOCK_WAIT:-7200}"

# Alert destination is shared with the vhost-listen tooling so there is one address to
# fill in per host rather than two that can disagree.
CONFIG="${DA_BACKUP_CONF:-/etc/da-vhost-listen/vhost-listen.conf}"
HEALTH_ALERT_TO=""

# Backstop sweep for system backup dirs an earlier run failed to remove.
SYSTEM_KEEP_DAYS="${DA_BACKUP_SYSTEM_KEEP_DAYS:-7}"
# Used% at or above which a *successful* run is still worth an alert: cleanup worked and
# the disk is full anyway, so something other than backups is consuming the volume.
ALERT_USED_PCT="${DA_BACKUP_ALERT_USED_PCT:-90}"

HOST="$(hostname -s)"
# Frozen once. A multi-hour upload that crosses midnight must not change destination
# prefix half way through, and cleanup must not resolve a different day than upload did.
DATE="$(date +%F)"
SYSTEM_DIR_STAMP="$(date +%m-%d-%y)"
DEST="${REMOTE}:${BUCKET}/${HOST}/${DATE}/"

RCLONE_OPTS=(
  --s3-no-check-bucket
  --checksum
  --transfers 4
  --checkers 8
  --log-file "$LOG"
  --log-level INFO
)

# --one-way: both uploads land in the same dated prefix, so the admin check must ignore
# the objects the system upload put there (and vice versa) instead of calling them extra.
CHECK_OPTS=(
  --s3-no-check-bucket
  --one-way
  --checksum
  --checkers 8
  --log-file "$LOG"
  --log-level NOTICE
)

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

# Same guards as the vhost-listen tooling: an address that can never receive mail is
# reported as broken alerting rather than logged as a successful send.
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

  # Branch on the submission status. `|| true` here would log "OK alert mailed" for a
  # message the local MTA rejected, and since DirectAdmin discards hook output this log
  # is the only evidence a backup left the disk full. There is no cooldown: backups run
  # on a schedule measured in days, so every failed run deserves its own mail.
  local mail_out mail_rc=0
  mail_out="$(printf '%s\n' "$body" | mail -s "$subject" "$dest" 2>&1)" || mail_rc=$?
  if ((mail_rc == 0)); then
    log "OK alert mailed to ${dest}"
  else
    log "ERROR alert submission FAILED (mail rc=${mail_rc}) to ${dest}: ${mail_out:-no output}"
  fi
}

disk_summary() {
  local path="$1"
  df -Pk "$path" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); printf "%s %d%% used, %.1f GB free", $6, $5, $4/1048576}'
}

disk_used_pct() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}'
}

size_of() {
  du -sh "$1" 2>/dev/null | cut -f1
}

# Dated DirectAdmin backup directories are MM-DD-YY.
dated_dir_count() {
  local d n=0
  for d in "$1"/*; do
    [[ -d "$d" ]] || continue
    [[ "$(basename "$d")" =~ ^[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] && n=$((n + 1))
  done
  printf '%d' "$n"
}

# Pick the root DirectAdmin is really writing to, preferring whichever candidate holds
# dated backup directories. An explicit DA_BACKUP_SYSTEM_ROOT always wins so a host with
# a non-standard layout, and the offline proof, can pin it.
resolve_system_root() {
  if [[ -n "$SYSTEM_ROOT" ]]; then
    return 0
  fi

  local candidate best="" best_count=0 populated=()
  for candidate in $SYSTEM_ROOT_CANDIDATES; do
    [[ -d "$candidate" ]] || continue
    [[ -n "$best" ]] || best="$candidate"
    local count
    count="$(dated_dir_count "$candidate")"
    if ((count > 0)); then
      populated+=("${candidate} (${count} dated dir(s))")
      if ((count > best_count)); then
        best="$candidate"
        best_count="$count"
      fi
    fi
  done

  SYSTEM_ROOT="${best:-/home/backup}"

  # Two populated roots means backups are being written to a path this run will not
  # clean. Say so rather than quietly picking one and leaving the other to fill the disk.
  if ((${#populated[@]} > 1)); then
    log "WARN system backups found under more than one root: ${populated[*]}; this run only handles ${SYSTEM_ROOT}"
  fi
}

resolve_system_root

# Only one run at a time. The admin and system hooks are separate DirectAdmin events
# that can overlap, and two concurrent runs would race: one deletes the files the other
# is still uploading. Waiting is correct here -- skipping would leave the disk full,
# which is the failure this hook is supposed to prevent.
lock_fd=""
lock_dir="$(dirname "$LOCK")"
if [[ -d "$lock_dir" && -w "$lock_dir" ]] || [[ -w "$LOCK" ]]; then
  exec 9>"$LOCK" && lock_fd=9
fi
if [[ -n "$lock_fd" ]] && command -v flock >/dev/null 2>&1; then
  if ! flock -w "$LOCK_WAIT_SEC" 9; then
    log "ERROR another run held ${LOCK} for more than ${LOCK_WAIT_SEC}s; exiting without touching local backups"
    alert "DirectAdmin backup upload stalled on ${HOST}" \
      "A da-backup-s3 run waited ${LOCK_WAIT_SEC}s for ${LOCK} and gave up, so this backup was neither uploaded nor cleaned up.

Local backups: $(disk_summary "$SYSTEM_ROOT")
Check for a stuck rclone: pgrep -a rclone; tail -50 ${LOG}"
    exit 1
  fi
fi

admin_uploaded=0
admin_list=""
admin_count=0

# Backups that reached S3 but could not be removed locally. Separate from the upload
# failures below because the fix differs -- these are safe to delete by hand -- but they
# are reported just as loudly, since a failed delete leaves the volume filling.
cleanup_failures=()

upload_admin() {
  [[ -d "$ADMIN_DIR" ]] || {
    log "skip admin: ${ADMIN_DIR} does not exist"
    return 0
  }

  local rc=0
  admin_list="$(mktemp)" || {
    log "ERROR could not create temp file for the admin upload list"
    return 1
  }
  # Enumerate once; copy, verify, and delete all read this same list. A backup that
  # appears mid-run is therefore uploaded by the next run rather than deleted here
  # without ever having been verified.
  (cd "$ADMIN_DIR" && find . -type f -printf '%P\n') >"$admin_list" 2>/dev/null
  admin_count="$(grep -c . "$admin_list" 2>/dev/null || echo 0)"

  if ((admin_count == 0)); then
    log "skip admin: no files under ${ADMIN_DIR}"
    return 0
  fi

  log "upload ${ADMIN_DIR} (${admin_count} files, $(size_of "$ADMIN_DIR")) -> ${DEST}"
  rclone copy "$ADMIN_DIR" "$DEST" --files-from "$admin_list" "${RCLONE_OPTS[@]}" || rc=$?
  if ((rc != 0)); then
    log "ERROR admin upload failed (rclone copy rc=${rc}); keeping local copies for the next run"
    return 1
  fi

  # Verify rather than trusting the exit status. Deleting the only copy of a backup is
  # unrecoverable, and this is the last point at which S3 can be asked to confirm.
  rc=0
  rclone check "$ADMIN_DIR" "$DEST" --files-from "$admin_list" "${CHECK_OPTS[@]}" || rc=$?
  if ((rc != 0)); then
    log "ERROR admin upload not verified in S3 (rclone check rc=${rc}); keeping local copies"
    return 1
  fi

  log "OK admin upload verified in S3 (${admin_count} files)"
  admin_uploaded=1
  return 0
}

cleanup_admin_local() {
  ((admin_uploaded == 1)) || return 0

  local f removed=0 kept=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if rm -f -- "${ADMIN_DIR}/${f}" 2>/dev/null; then
      removed=$((removed + 1))
    else
      kept=$((kept + 1))
    fi
  done <"$admin_list"

  # Drop the per-user staging directories the deletes above just emptied. Directories
  # that still hold a file gained it after the upload was enumerated, so they are left
  # alone for the next run instead of being rm -rf'd unverified.
  find "$ADMIN_DIR" -mindepth 1 -depth -type d -empty ! -name '.*' -delete 2>/dev/null

  log "cleaned ${removed} verified file(s) from ${ADMIN_DIR}"

  # A delete that fails leaves an archive that is already in S3 occupying local disk.
  # Skipping it silently is how a run could leave the volume filling and still exit 0
  # reporting "backup upload and local cleanup complete".
  if ((kept > 0)); then
    log "ERROR could not remove ${kept} verified file(s) from ${ADMIN_DIR}"
    cleanup_failures+=("${kept} verified file(s) under ${ADMIN_DIR} ($(size_of "$ADMIN_DIR") still on disk)")
  fi
}

system_dir=""
system_uploaded=0

resolve_system_dir() {
  [[ -d "$SYSTEM_ROOT" ]] || return 0

  local candidate="${SYSTEM_ROOT}/${SYSTEM_DIR_STAMP}"
  if [[ -d "$candidate" ]]; then
    system_dir="$candidate"
    return 0
  fi

  # DirectAdmin names these for the day the backup started, which is not today when the
  # run began before midnight or the schedule slipped. Fall back to the newest directory
  # and -- crucially -- record it, so cleanup removes what upload actually sent.
  candidate="$(find "$SYSTEM_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
  if [[ -n "$candidate" && -d "$candidate" ]]; then
    system_dir="$candidate"
    log "NOTE ${SYSTEM_ROOT}/${SYSTEM_DIR_STAMP} does not exist; using newest directory ${system_dir}"
  fi
  return 0
}

upload_system() {
  [[ -n "$system_dir" ]] || {
    log "skip system: no backup directory under ${SYSTEM_ROOT}"
    return 0
  }

  local rc=0
  log "upload ${system_dir} ($(size_of "$system_dir")) -> ${DEST}"
  rclone copy "$system_dir" "$DEST" "${RCLONE_OPTS[@]}" || rc=$?
  if ((rc != 0)); then
    log "ERROR system upload failed (rclone copy rc=${rc}); keeping ${system_dir} for the next run"
    return 1
  fi

  rc=0
  rclone check "$system_dir" "$DEST" "${CHECK_OPTS[@]}" || rc=$?
  if ((rc != 0)); then
    log "ERROR system upload not verified in S3 (rclone check rc=${rc}); keeping ${system_dir}"
    return 1
  fi

  log "OK system upload verified in S3 (${system_dir})"
  system_uploaded=1
  return 0
}

cleanup_system_local() {
  ((system_uploaded == 1)) || return 0
  # Same variable upload_system used. The old code recomputed the date here, which is
  # how a verified upload could be followed by a cleanup that deleted nothing.
  local freed
  freed="$(size_of "$system_dir")"
  if rm -rf -- "$system_dir"; then
    log "cleaned ${system_dir} (${freed} reclaimed)"
  else
    log "ERROR could not remove ${system_dir} after a verified upload"
    cleanup_failures+=("${system_dir} (${freed}) -- verified in S3 but could not be deleted")
  fi
}

# Where a backup taken on MM-DD-YY would have been uploaded: the hook names the prefix
# for the day it runs, which is the day the backup was taken.
s3_prefix_for_stamp() {
  local stamp="$1"
  [[ "$stamp" =~ ^([0-9]{2})-([0-9]{2})-([0-9]{2})$ ]] || return 1
  printf '%s:%s/%s/20%s-%s-%s/' \
    "$REMOTE" "$BUCKET" "$HOST" "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

unverified_dirs=()

# Backstop for directories an earlier run uploaded but failed to remove.
#
# The obvious implementation -- find -mtime +N -exec rm -rf -- is the one that would have
# destroyed 52 GB of the primary's only copies. Nine weekly archives had accumulated
# under /backup because the hook was cleaning the wrong root, and not one of them had
# ever reached S3; an age sweep pointed at the corrected root would have deleted eight of
# them on its first run. Age says a backup is old, not that it is safe to delete. Ask S3.
sweep_old_system_dirs() {
  [[ -d "$SYSTEM_ROOT" ]] || return 0

  local d stamp prefix rc
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    stamp="$(basename "$d")"

    if ! prefix="$(s3_prefix_for_stamp "$stamp")"; then
      log "WARN keeping ${d} ($(size_of "$d")): name is not an MM-DD-YY stamp, so there is no prefix to verify it against"
      unverified_dirs+=("${d} ($(size_of "$d")) -- unrecognised name")
      continue
    fi

    rc=0
    rclone check "$d" "$prefix" "${CHECK_OPTS[@]}" || rc=$?
    if ((rc != 0)); then
      log "WARN keeping ${d} ($(size_of "$d")): not present in ${prefix} (rclone check rc=${rc}). This is a local-only backup, not stale cleanup."
      unverified_dirs+=("${d} ($(size_of "$d")) -- not in ${prefix}")
      continue
    fi

    log "sweeping ${d} ($(size_of "$d")): older than ${SYSTEM_KEEP_DAYS}d and confirmed in ${prefix}"
    rm -rf -- "$d"
  done < <(find "$SYSTEM_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+${SYSTEM_KEEP_DAYS}" ! -path "${system_dir:-/nonexistent}" 2>/dev/null)
}

resolve_system_dir

log "start ${HOST} -> ${DEST} (${SYSTEM_ROOT}: $(disk_summary "$SYSTEM_ROOT"))"

failures=()
upload_admin || failures+=("admin backups under ${ADMIN_DIR}")
upload_system || failures+=("system backup ${system_dir:-under $SYSTEM_ROOT}")

# Both cleanups run regardless of the other unit's outcome, and each is gated on its own
# verified upload. A failed system upload no longer keeps admin archives on disk.
cleanup_admin_local
cleanup_system_local
sweep_old_system_dirs

[[ -n "$admin_list" && -f "$admin_list" ]] && rm -f "$admin_list"

used_pct="$(disk_used_pct "$SYSTEM_ROOT")"
used_pct="${used_pct:-0}"
log "finished (${SYSTEM_ROOT}: $(disk_summary "$SYSTEM_ROOT"))"

if ((${#failures[@]} > 0)) || ((${#cleanup_failures[@]} > 0)); then
  # Both kinds of failure leave backups on local disk, which is the condition that ends in
  # a full volume, so both mail. They are listed separately because the remedies differ:
  # an upload retries on the next run, whereas a verified-but-undeletable copy needs a
  # human to remove it (a read-only remount, an immutable attribute, or an I/O error).
  detail=""
  subject_what="upload"
  if ((${#failures[@]} > 0)); then
    log "ERROR ${#failures[@]} upload(s) failed; local backups were kept"
    detail+="Not uploaded to S3, still on local disk, will be retried by the next run:
$(printf '  - %s\n' "${failures[@]}")
"
  fi
  if ((${#cleanup_failures[@]} > 0)); then
    log "ERROR ${#cleanup_failures[@]} local cleanup(s) failed after a verified upload"
    if ((${#failures[@]} > 0)); then
      subject_what="upload and local cleanup"
    else
      subject_what="local cleanup"
    fi
    detail+="Uploaded and verified in S3, but the local copy could NOT be removed. These are safe to delete by hand; find out what blocked the delete (read-only filesystem, chattr +i, I/O error):
$(printf '  - %s\n' "${cleanup_failures[@]}")
"
  fi
  alert "DirectAdmin backup ${subject_what} FAILED on ${HOST} (disk ${used_pct}% used)" \
    "Backups on ${HOST} are still occupying the local disk after this run. Two consecutive failures put the root volume at risk.

${detail}
Disk: $(disk_summary "$SYSTEM_ROOT")
Local backup usage:
$(du -sh "$ADMIN_DIR" "$SYSTEM_ROOT" 2>/dev/null | sed 's/^/  /')

Recent log:
$(tail -20 "$LOG" 2>/dev/null | sed 's/^/  /')

Runbook: aws/docs/2026-09-06-primary-outage.md
Retry by hand: /usr/local/directadmin/scripts/custom/all_backups_post.sh"
  exit 1
fi

if ((${#unverified_dirs[@]} > 0)); then
  # These are old enough to sweep but are not in S3, so they are the only copy. Deleting
  # them is a data-loss decision and belongs to a human, not to a -mtime predicate.
  log "WARN ${#unverified_dirs[@]} old system backup dir(s) kept because they are not in S3"
  alert "Local-only system backups on ${HOST} (disk ${used_pct}% used)" \
    "These system backup directories are older than ${SYSTEM_KEEP_DAYS} days but are NOT in S3, so they were kept. They are consuming disk as the only copy of that data:

$(printf '  - %s\n' "${unverified_dirs[@]}")

Either upload them:
  rclone copy <dir> ${REMOTE}:${BUCKET}/${HOST}/<YYYY-MM-DD>/ --s3-no-check-bucket --checksum
or decide they are not worth keeping and remove them by hand.

Disk: $(disk_summary "$SYSTEM_ROOT")
Runbook: aws/docs/2026-09-06-primary-outage.md"
fi

if ((used_pct >= ALERT_USED_PCT)); then
  # Uploads and cleanup both worked and the volume is still nearly full, so the space is
  # going somewhere this hook does not manage. Worth a mail before it becomes an outage.
  log "WARN ${SYSTEM_ROOT} is ${used_pct}% used after a clean run"
  alert "Disk still ${used_pct}% used after a clean backup run on ${HOST}" \
    "Every backup uploaded, and every local copy this hook manages was removed -- a failed delete exits earlier with its own mail, so reaching this alert means cleanup genuinely succeeded. ${SYSTEM_ROOT} is nonetheless ${used_pct}% used, so something outside the backup hook is filling this volume.

Disk: $(disk_summary "$SYSTEM_ROOT")
Largest directories under /:
$(du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -15 | sed 's/^/  /')

Runbook: aws/docs/2026-09-06-primary-outage.md"
fi

log "OK backup upload and local cleanup complete"
exit 0
