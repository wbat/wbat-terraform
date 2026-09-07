#!/bin/bash
# Offline proof that all_backups_post.sh frees local disk when it should and keeps the
# only copy of a backup when it should. No box access, no S3, no DirectAdmin: rclone and
# mail are stubbed and every path is redirected into a temp sandbox.
#
# Each proof below is a failure mode that actually happened or was one transient error
# away from happening (see aws/docs/2026-09-06-primary-outage.md). All nine fail against
# the pre-2026-09-06 hook, with three wrinkles worth stating:
#
#   - Proof 1's "keep the data" half passed there, but only because `set -e` aborted the
#     run before cleanup could delete anything. It failed the half that matters for an
#     outage -- nobody was told.
#   - Proof 8 fails against the *fix* as well as the original. Correcting the backup root
#     (proof 7) is what first points a working age sweep at real data, and on the primary
#     that data was never in S3. Both proofs have been checked against the behaviour they
#     describe, so neither can pass vacuously.
#   - Proof 9 also fails against the fix. Every earlier proof is about which files survive;
#     this one is about whether anyone is told when they survive by accident, which the
#     rewrite still got wrong: a failed delete was skipped without being counted.
#
# Usage (from repo root):
#   ./scripts/directadmin/prove_backup_cleanup.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${ROOT}/scripts/directadmin/all_backups_post.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "ERROR: missing or non-executable hook $HOOK" >&2
  exit 1
fi

SANDBOX="$(mktemp -d)"
# Proof 9 drops the write bit on a directory to make rm fail, and rm -rf cannot remove a
# file from a directory it cannot write to either. Restore permissions first so a failing
# assertion still cleans up after itself.
trap 'chmod -R u+rwX "$SANDBOX" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT

# Stub rclone: records its arguments and returns whatever the proof asked for, so a
# failing upload and an upload that fails verification can be told apart.
mkdir -p "${SANDBOX}/bin"
cat >"${SANDBOX}/bin/rclone" <<'STUB'
#!/bin/bash
subcommand="$1"
echo "rclone $*" >>"${STUB_CALLS}"
# Record the upload list too: the hook passes files by --files-from, so the filenames
# are not visible in the argv a proof would otherwise assert on.
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--files-from" && -f "$arg" ]]; then
    sed 's/^/  files-from: /' "$arg" >>"${STUB_CALLS}"
  fi
  prev="$arg"
done
case "$subcommand" in
  copy)
    # Optionally drop a new file into the source mid-"upload" to prove the hook only
    # deletes what it enumerated and verified.
    if [[ -n "${STUB_COPY_CREATES:-}" ]]; then
      : >"${STUB_COPY_CREATES}"
    fi
    exit "${STUB_COPY_RC:-0}"
    ;;
  check)
    # Let a proof fail verification for one specific destination prefix, so "this old
    # directory is in S3" and "this one never made it" can be exercised in a single run.
    if [[ -n "${STUB_CHECK_FAIL_MATCH:-}" ]]; then
      for arg in "$@"; do
        [[ "$arg" == *"${STUB_CHECK_FAIL_MATCH}"* ]] && exit 1
      done
    fi
    exit "${STUB_CHECK_RC:-0}"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${SANDBOX}/bin/rclone"

# Stub mail: captures the alert so "did this run alert anyone?" is checkable.
cat >"${SANDBOX}/bin/mail" <<'STUB'
#!/bin/bash
{
  echo "to/subject: $*"
  cat
} >>"${STUB_MAIL}"
exit 0
STUB
chmod +x "${SANDBOX}/bin/mail"

cat >"${SANDBOX}/backup.conf" <<'CONF'
HEALTH_ALERT_TO="ops@wbat.net"
CONF

# One run of the hook against a freshly built sandbox.
#   setup_fn      shell function that populates admin_backups / backup
#   expectation   printed context on failure
run_hook() {
  local case_dir="${SANDBOX}/$1"
  shift
  rm -rf "$case_dir"
  mkdir -p "${case_dir}/admin_backups" "${case_dir}/backup" "${case_dir}/lock"

  ADMIN_DIR="${case_dir}/admin_backups"
  SYSTEM_ROOT="${case_dir}/backup"
  HOOK_LOG="${case_dir}/da-backup-s3.log"
  STUB_CALLS="${case_dir}/rclone.calls"
  STUB_MAIL="${case_dir}/mail.out"
  : >"$STUB_CALLS"
  : >"$STUB_MAIL"

  "$@" # case-specific fixture setup

  # Default to the system event. Every proof that asserts on the system tree is modelling
  # "a system backup finished and DirectAdmin fired its hook", which on a host is
  # system_backup_post.sh passing --event=system. Fixtures create their directories a
  # moment before the run, so under the admin event the in-progress guard would defer them
  # -- correctly, but that is Proof 12's subject, not theirs.
  #
  # Pinning DA_BACKUP_SYSTEM_ROOT is what most proofs want, but the root-detection proof
  # has to leave it empty so the hook chooses between candidates the way it does on a host.
  local root_env=(DA_BACKUP_SYSTEM_ROOT="$SYSTEM_ROOT")
  if [[ -n "${STUB_ROOT_CANDIDATES:-}" ]]; then
    root_env=(DA_BACKUP_SYSTEM_ROOT="" DA_BACKUP_SYSTEM_ROOTS="$STUB_ROOT_CANDIDATES")
  fi

  set +e
  env PATH="${SANDBOX}/bin:${PATH}" \
    STUB_CALLS="$STUB_CALLS" \
    STUB_MAIL="$STUB_MAIL" \
    STUB_COPY_RC="${STUB_COPY_RC:-0}" \
    STUB_CHECK_RC="${STUB_CHECK_RC:-0}" \
    STUB_CHECK_FAIL_MATCH="${STUB_CHECK_FAIL_MATCH:-}" \
    STUB_COPY_CREATES="${STUB_COPY_CREATES:-}" \
    DA_BACKUP_ADMIN_DIR="$ADMIN_DIR" \
    "${root_env[@]}" \
    DA_BACKUP_SYSTEM_KEEP_DAYS="${DA_BACKUP_SYSTEM_KEEP_DAYS:-7}" \
    DA_BACKUP_SYSTEM_QUIESCE_SEC="${DA_BACKUP_SYSTEM_QUIESCE_SEC:-900}" \
    DA_BACKUP_LOG="$HOOK_LOG" \
    DA_BACKUP_LOCK="${case_dir}/lock/da-backup-s3.lock" \
    DA_BACKUP_CONF="${SANDBOX}/backup.conf" \
    DA_BACKUP_ALERT_USED_PCT="${DA_BACKUP_ALERT_USED_PCT:-101}" \
    DA_BACKUP_EVENT="${DA_BACKUP_EVENT:-system}" \
    "$HOOK" >"${case_dir}/stderr" 2>&1
  HOOK_RC=$?
  set -e
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_admin_archive() { dd if=/dev/zero of="${ADMIN_DIR}/$1" bs=1k count=64 status=none; }
make_system_dir() {
  mkdir -p "${SYSTEM_ROOT}/$1/mysql"
  dd if=/dev/zero of="${SYSTEM_ROOT}/$1/mysql/db.sql.gz" bs=1k count=64 status=none
}

##############################################################################
echo "== Proof 1: a failed upload must NOT delete local backups, and must alert =="
##############################################################################
# The pre-fix hook had `set -e` with both cleanups after both uploads, so this case
# skipped cleanup too -- but silently, exit 1 into a log nobody read, and the next
# backup stacked another full set on top.
fixture_1() {
  make_admin_archive user1.tar.zst
  make_system_dir "$(date +%m-%d-%y)"
}
STUB_COPY_RC=1 run_hook case1 fixture_1
unset STUB_COPY_RC

[[ -f "${SANDBOX}/case1/admin_backups/user1.tar.zst" ]] \
  || fail "admin archive deleted after a failed upload (data loss)"
[[ -d "${SANDBOX}/case1/backup/$(date +%m-%d-%y)" ]] \
  || fail "system backup deleted after a failed upload (data loss)"
((HOOK_RC != 0)) || fail "hook reported success after a failed upload"
grep -q 'BACKUP UPLOAD FAILED\|backup upload FAILED' "${SANDBOX}/case1/mail.out" \
  || fail "no alert mailed for a failed upload (this is what made it silent)"
grep -q 'user1.tar.zst' "${SANDBOX}/case1/rclone.calls" \
  || fail "hook never attempted to upload the admin archive"
echo "OK failed upload keeps both local copies, exits non-zero, and mails an alert"

##############################################################################
echo "== Proof 2: a verified upload of a NON-today system dir must be deleted =="
##############################################################################
# This is the bug that filled the disk. Upload resolves the newest directory when
# today's does not exist (hook firing after midnight, or a slipped schedule), while the
# old cleanup recomputed `date +%m-%d-%y`, found nothing, logged "cleaned local system
# backup dirs" and exited 0. Tens of GB stayed put behind a clean-looking log.
YDAY="$(date -d yesterday +%m-%d-%y 2>/dev/null || date -v-1d +%m-%d-%y)"
fixture_2() { make_system_dir "$YDAY"; }
run_hook case2 fixture_2

[[ ! -d "${SANDBOX}/case2/backup/${YDAY}" ]] \
  || fail "verified system backup ${YDAY} left on disk -- cleanup is looking at the wrong directory again"
((HOOK_RC == 0)) || fail "hook failed on a healthy run (rc=${HOOK_RC})"
grep -q "backup/${YDAY}" "${SANDBOX}/case2/rclone.calls" \
  || fail "hook uploaded a different directory than the one it cleaned"
echo "OK cleanup removes exactly the directory the upload resolved"

##############################################################################
echo "== Proof 3: an upload that cannot be verified in S3 must keep the local copy =="
##############################################################################
# rclone exiting 0 is not proof the objects are readable. Deleting the only copy of a
# backup is unrecoverable, so `check` gates the delete.
fixture_3() {
  make_admin_archive user1.tar.zst
  make_system_dir "$(date +%m-%d-%y)"
}
STUB_CHECK_RC=1 run_hook case3 fixture_3
unset STUB_CHECK_RC

[[ -f "${SANDBOX}/case3/admin_backups/user1.tar.zst" ]] \
  || fail "admin archive deleted despite failing verification"
[[ -d "${SANDBOX}/case3/backup/$(date +%m-%d-%y)" ]] \
  || fail "system backup deleted despite failing verification"
grep -q 'rclone check' "${SANDBOX}/case3/rclone.calls" || fail "hook never verified the upload"
((HOOK_RC != 0)) || fail "hook reported success on an unverifiable upload"
echo "OK unverified uploads are kept locally and reported"

##############################################################################
echo "== Proof 4: one failing upload must not block the other unit's cleanup =="
##############################################################################
# `set -e` made the two units share a fate: a system upload error left admin archives on
# disk even though they were safely in S3. Each cleanup is now gated on its own upload.
fixture_4() {
  make_admin_archive user1.tar.zst
  # No system dir at all, so the system upload path is skipped rather than failed;
  # a stray non-archive file proves cleanup is driven by the verified list, not a glob.
  : >"${ADMIN_DIR}/partial-backup.tar"
}
run_hook case4 fixture_4

[[ ! -f "${SANDBOX}/case4/admin_backups/user1.tar.zst" ]] \
  || fail "verified admin archive left on disk"
[[ ! -f "${SANDBOX}/case4/admin_backups/partial-backup.tar" ]] \
  || fail "stray .tar left behind: the old name-based cleanup only matched .tar.zst/.tar.gz"
((HOOK_RC == 0)) || fail "hook failed on a healthy admin-only run (rc=${HOOK_RC})"
echo "OK admin cleanup is independent, and covers files the old globs missed"

##############################################################################
echo "== Proof 5: a backup that appears mid-upload must not be deleted unverified =="
##############################################################################
# Cleanup used to rm -rf whatever matched at delete time, which is a different set than
# what was uploaded. Anything DirectAdmin wrote during a long upload was destroyed
# without ever reaching S3.
fixture_5() {
  make_admin_archive user1.tar.zst
  export STUB_COPY_CREATES="${ADMIN_DIR}/user2.tar.zst"
}
run_hook case5 fixture_5
unset STUB_COPY_CREATES

[[ ! -f "${SANDBOX}/case5/admin_backups/user1.tar.zst" ]] \
  || fail "verified admin archive left on disk"
[[ -f "${SANDBOX}/case5/admin_backups/user2.tar.zst" ]] \
  || fail "archive created mid-upload was deleted without being verified (data loss)"
echo "OK only enumerated, verified files are deleted; the rest waits for the next run"

##############################################################################
echo "== Proof 6: a clean run on a still-full disk must alert =="
##############################################################################
# Cleanup working and the volume staying full means something this hook does not manage
# is eating the disk. That deserves mail before it becomes an outage.
fixture_6() { make_admin_archive user1.tar.zst; }
DA_BACKUP_ALERT_USED_PCT=0 run_hook case6 fixture_6
unset DA_BACKUP_ALERT_USED_PCT

((HOOK_RC == 0)) || fail "still-full warning must not turn a successful upload into a failure"
grep -qi 'disk still' "${SANDBOX}/case6/mail.out" \
  || fail "no alert mailed when the disk stayed full after a clean run"
echo "OK a clean run on a full disk warns without failing the backup"

##############################################################################
echo "== Proof 7: the hook must clean the root DirectAdmin actually writes to =="
##############################################################################
# This is the defect that fired on the primary. SYSTEM_ROOT was hardcoded to /home/backup,
# which exists and is empty, while DirectAdmin wrote weekly archives to /backup. Every run
# logged "cleaned local system backup dirs under /home/backup" and freed nothing; nine
# weeks and 59 GB accumulated behind a log that read as healthy. Note this is invisible to
# proof 2: pin the root and the hook looks perfect.
CASE7="${SANDBOX}/case7"
TODAY="$(date +%m-%d-%y)"
fixture_7() {
  # First candidate empty (like /home/backup), second holds the real backups (like /backup).
  mkdir -p "${CASE7}/sysbackup/${TODAY}/mysql"
  dd if=/dev/zero of="${CASE7}/sysbackup/${TODAY}/mysql/db.sql.gz" bs=1k count=64 status=none
}
STUB_ROOT_CANDIDATES="${CASE7}/backup ${CASE7}/sysbackup" run_hook case7 fixture_7
unset STUB_ROOT_CANDIDATES

((HOOK_RC == 0)) || fail "hook failed on a healthy run against a detected root (rc=${HOOK_RC})"
grep -q "sysbackup/${TODAY}" "${CASE7}/rclone.calls" \
  || fail "hook never uploaded from the populated root -- it is still assuming a hardcoded path"
[[ ! -d "${CASE7}/sysbackup/${TODAY}" ]] \
  || fail "backup left on disk: the hook picked a root it was not writing to (the primary's bug)"
echo "OK the populated backup root is detected, uploaded, and cleaned"

##############################################################################
echo "== Proof 8: the age sweep must never delete a backup that is not in S3 =="
##############################################################################
# Fixing proof 7 is what makes this dangerous. Point a working -mtime sweep at the root
# that really holds the backups and its first run deletes eight weekly archives, none of
# which was ever uploaded -- 52 GB of the only copy, destroyed by the fix. Age means old,
# not safe. Here 07-04-26 is missing from S3 and must survive; 07-11-26 is present and
# should go.
CASE8="${SANDBOX}/case8"
fixture_8() {
  local d
  for d in 07-04-26 07-11-26; do
    mkdir -p "${SYSTEM_ROOT}/${d}/mysql"
    dd if=/dev/zero of="${SYSTEM_ROOT}/${d}/mysql/db.sql.gz" bs=1k count=64 status=none
    touch -t 202601010000 "${SYSTEM_ROOT}/${d}"
  done
  make_system_dir "$TODAY" # today's backup still uploads and cleans normally
}
STUB_CHECK_FAIL_MATCH="2026-07-04" DA_BACKUP_SYSTEM_KEEP_DAYS=7 run_hook case8 fixture_8
unset STUB_CHECK_FAIL_MATCH DA_BACKUP_SYSTEM_KEEP_DAYS

[[ -d "${CASE8}/backup/07-04-26" ]] \
  || fail "swept a backup that is not in S3 -- this is the 52 GB data-loss case"
[[ ! -d "${CASE8}/backup/07-11-26" ]] \
  || fail "kept a backup that S3 confirmed, so the sweep no longer reclaims anything"
[[ ! -d "${CASE8}/backup/${TODAY}" ]] || fail "today's verified backup was left on disk"
grep -qi 'local-only system backups' "${CASE8}/mail.out" \
  || fail "no alert for a local-only backup the sweep had to keep"
((HOOK_RC == 0)) || fail "keeping an unverified directory must not fail the run (rc=${HOOK_RC})"
echo "OK the sweep deletes only what S3 confirms, and reports what it kept"

##############################################################################
echo "== Proof 9: a verified upload whose local delete fails must not report success =="
##############################################################################
# The quiet half of "fail loudly". A read-only remount, an immutable attribute or an I/O
# error can make rm fail after the upload has already been verified, so the archive stays
# on disk and keeps filling the volume. The hook counted only successful deletes, recorded
# nothing, exited 0, and logged "backup upload and local cleanup complete". The single
# alert that could still have fired was the disk-usage one -- whose body asserted that
# every local copy had been removed, pointing the reader away from the real cause.
CASE9="${SANDBOX}/case9"
fixture_9() {
  make_admin_archive user1.tar.zst
  make_system_dir "$TODAY"
  # Deleting a file needs write permission on its directory, so dropping the write bit
  # makes rm fail without root and without a genuinely read-only mount.
  chmod 500 "$ADMIN_DIR"
}
run_hook case9 fixture_9
chmod 700 "${CASE9}/admin_backups"

[[ -f "${CASE9}/admin_backups/user1.tar.zst" ]] \
  || fail "fixture did not hold: the archive was deleted after all, so this proves nothing"
((HOOK_RC != 0)) \
  || fail "hook exited 0 with a verified backup still on disk -- exactly the silent failure"
grep -q 'backup local cleanup FAILED' "${CASE9}/mail.out" \
  || fail "a failed delete must mail, and must name cleanup rather than upload:"$'\n'"$(cat "${CASE9}/mail.out")"
grep -q 'could NOT be removed' "${CASE9}/mail.out" \
  || fail "the alert must name the leftover so a human can remove it"
grep -q 'ERROR could not remove 1 verified file(s)' "${CASE9}/da-backup-s3.log" \
  || fail "the failed delete was not logged as an error"
[[ ! -d "${CASE9}/backup/${TODAY}" ]] \
  || fail "an admin cleanup failure blocked the system cleanup; the two must stay independent"
echo "OK an undeletable verified backup fails the run and names itself in the alert"

##############################################################################
echo "== Proof 10: the same failure in the age sweep must also be reported =="
##############################################################################
# Proof 9 covers the two cleanup helpers. The sweep is a third path that deletes verified
# backups, and it was left with a bare 'rm -rf' -- so the one route that exists specifically
# to clear a backlog could fail to clear it and still report a clean run. The backlog is the
# whole reason the volume reached 99%, which makes silence here worse than in the helpers,
# not better.
#
# 07-11-26 is old enough to sweep and confirmed in S3, so the sweep decides to delete it.
# Its mysql/ subdirectory is not writable, so rm cannot empty it and the tree survives.
# SYSTEM_ROOT itself stays writable, which keeps today's cleanup working and proves the
# failure is attributed to the sweep rather than leaking from the helper.
CASE10="${SANDBOX}/case10"
fixture_10() {
  mkdir -p "${SYSTEM_ROOT}/07-11-26/mysql"
  dd if=/dev/zero of="${SYSTEM_ROOT}/07-11-26/mysql/db.sql.gz" bs=1k count=64 status=none
  touch -t 202601010000 "${SYSTEM_ROOT}/07-11-26"
  make_system_dir "$TODAY"
  chmod 500 "${SYSTEM_ROOT}/07-11-26/mysql"
}
DA_BACKUP_SYSTEM_KEEP_DAYS=7 run_hook case10 fixture_10
unset DA_BACKUP_SYSTEM_KEEP_DAYS
chmod 700 "${CASE10}/backup/07-11-26/mysql"

[[ -f "${CASE10}/backup/07-11-26/mysql/db.sql.gz" ]] \
  || fail "fixture did not hold: the sweep removed the directory, so this proves nothing"
((HOOK_RC != 0)) \
  || fail "the sweep failed to reclaim a backlog directory and the hook still exited 0"
grep -q 'backup local cleanup FAILED' "${CASE10}/mail.out" \
  || fail "a failed sweep must mail:"$'\n'"$(cat "${CASE10}/mail.out")"
grep -q '07-11-26' "${CASE10}/mail.out" \
  || fail "the alert must name the directory that is still using disk"
grep -q 'ERROR could not remove .*07-11-26' "${CASE10}/da-backup-s3.log" \
  || fail "the failed sweep delete was not logged as an error"
[[ ! -d "${CASE10}/backup/${TODAY}" ]] \
  || fail "a sweep failure blocked today's cleanup; the paths must stay independent"
echo "OK a sweep that cannot reclaim its target says so"

##############################################################################
echo "== Proof 11: a partial enumeration must not be treated as the whole list =="
##############################################################################
# Everything downstream trusts the enumerated list -- upload reads it, verify reads it,
# delete reads it. So a list that is short is worse than no list at all: the hook uploads
# and deletes exactly the files it managed to see, leaves the rest on disk, and reports a
# clean run. find signals this by exiting non-zero while still writing what it got, and
# that status was being discarded along with stderr.
#
# An unreadable subdirectory reproduces it without root: find cannot descend, so it emits
# the files it already found, warns, and exits 1.
CASE11="${SANDBOX}/case11"
fixture_11() {
  make_admin_archive visible.tar.zst
  mkdir -p "${ADMIN_DIR}/locked"
  : >"${ADMIN_DIR}/locked/hidden.tar.zst"
  chmod 000 "${ADMIN_DIR}/locked"
}
run_hook case11 fixture_11
chmod 700 "${CASE11}/admin_backups/locked"

[[ -f "${CASE11}/admin_backups/locked/hidden.tar.zst" ]] \
  || fail "fixture did not hold: the unreadable file was somehow enumerated"
[[ -f "${CASE11}/admin_backups/visible.tar.zst" ]] \
  || fail "the hook deleted the files it could see while others were unaccounted for"
((HOOK_RC != 0)) \
  || fail "a partial enumeration reported success -- the whole point is that it cannot"
grep -q 'ERROR could not enumerate' "${CASE11}/da-backup-s3.log" \
  || fail "the enumeration failure was not logged:"$'\n'"$(cat "${CASE11}/da-backup-s3.log")"
grep -q 'DirectAdmin backup upload FAILED' "${CASE11}/mail.out" \
  || fail "a partial enumeration must mail like any other upload failure"
echo "OK an incomplete file list fails the run instead of defining it"

##############################################################################
echo "== Proof 12: a system backup still being written must not be uploaded or deleted =="
##############################################################################
# The most destructive path this branch opened. system_backup_post.sh execs this same
# script, so a run cannot tell from the filesystem which DirectAdmin event started it. An
# admin backup finishing at 03:10 finds today's system directory -- which the weekly
# system backup is still writing into -- uploads the fraction that exists, verifies that
# fraction against what it just uploaded, and rm -rf's the tree out from under sysbk. S3
# then holds a partial archive recorded as a complete one, which is worse than holding
# nothing. The flock does not help: it serialises hook runs, not the backup process.
#
# This was unreachable while SYSTEM_ROOT pointed at an empty /home/backup. Detecting the
# real root is what made it live, so the fix and the hazard arrived in the same change.
CASE12="${SANDBOX}/case12"
fixture_12() {
  make_admin_archive user1.tar.zst
  make_system_dir "$TODAY"
  # Being written to right now.
  touch "${SYSTEM_ROOT}/${TODAY}/mysql/db.sql.gz"
}
DA_BACKUP_EVENT=admin run_hook case12 fixture_12
unset DA_BACKUP_EVENT

[[ -d "${CASE12}/backup/${TODAY}" ]] \
  || fail "the admin event deleted a system backup that was still being written"
((HOOK_RC == 0)) \
  || fail "deferring a live directory is normal operation, not a failure (rc=${HOOK_RC})"
grep -q "NOTE deferring .*${TODAY}" "${CASE12}/da-backup-s3.log" \
  || fail "the deferral must be logged:"$'\n'"$(cat "${CASE12}/da-backup-s3.log")"
grep -q 'left in place' "${CASE12}/da-backup-s3.log" \
  || fail "the completion line must not claim cleanup was complete when a directory was skipped"
[[ ! -f "${CASE12}/admin_backups/user1.tar.zst" ]] \
  || fail "deferring the system tree must not stop admin cleanup; the two are independent"
echo "OK an in-progress system backup is left alone by the admin event"

# The system event is DirectAdmin's completion signal, so the identical directory must be
# uploaded and cleaned immediately -- otherwise the guard above would just be a leak.
CASE13="${SANDBOX}/case13"
fixture_13() {
  make_system_dir "$TODAY"
  touch "${SYSTEM_ROOT}/${TODAY}/mysql/db.sql.gz"
}
DA_BACKUP_EVENT=system run_hook case13 fixture_13
unset DA_BACKUP_EVENT

[[ ! -d "${CASE13}/backup/${TODAY}" ]] \
  || fail "the system event is the completion signal and must still clean up promptly"
((HOOK_RC == 0)) || fail "the system event run failed (rc=${HOOK_RC})"
echo "OK the system event still cleans the directory it was fired for"

# And the guard must be a deferral, not a refusal. A directory that has stopped changing
# is a finished backup whose hook never cleaned it -- the backlog case, and the reason the
# admin event looks at the system tree at all. If this did not hold, the fix would trade
# one silent leak for another.
CASE16="${SANDBOX}/case16"
fixture_16() {
  make_system_dir "$TODAY"
  find "${SYSTEM_ROOT}/${TODAY}" -exec touch -t 202601010000 {} +
  touch -t 202601010000 "${SYSTEM_ROOT}/${TODAY}"
}
DA_BACKUP_EVENT=admin run_hook case16 fixture_16
unset DA_BACKUP_EVENT

[[ ! -d "${CASE16}/backup/${TODAY}" ]] \
  || fail "a settled directory was deferred forever; the admin event must still clear a backlog"
((HOOK_RC == 0)) || fail "clearing a settled directory must not fail the run (rc=${HOOK_RC})"
echo "OK a directory that has stopped changing is still collected by the admin event"

##############################################################################
echo "== Proof 13: backups under a root this run ignores must reach a person =="
##############################################################################
# Picking the more populated root leaves the other one growing with nothing managing it.
# That was logged, and a log is not a notification -- the entire failure being fixed here
# is a hook writing reassuring lines into a file nobody opened while the volume filled.
CASE14="${SANDBOX}/case14"
fixture_14() {
  make_system_dir "$TODAY" # the root detection will choose this one
  make_system_dir "09-06-26"
  mkdir -p "${CASE14}/sysbackup/07-04-26/mysql"
  : >"${CASE14}/sysbackup/07-04-26/mysql/db.sql.gz"
}
STUB_ROOT_CANDIDATES="${SANDBOX}/case14/backup ${SANDBOX}/case14/sysbackup" \
  run_hook case14 fixture_14
unset STUB_ROOT_CANDIDATES

grep -q 'more than one root' "${CASE14}/da-backup-s3.log" \
  || fail "the second populated root was not detected:"$'\n'"$(cat "${CASE14}/da-backup-s3.log")"
grep -q 'unhandled root' "${CASE14}/mail.out" \
  || fail "an unmanaged backup tree must mail, not just log:"$'\n'"$(cat "${CASE14}/mail.out")"
grep -q 'sysbackup' "${CASE14}/mail.out" \
  || fail "the alert must name the root that is being ignored"
echo "OK an ignored backup root is reported to a human"

##############################################################################
echo "== Proof 14: a sweep that cannot list its candidates must not claim success =="
##############################################################################
# Same discarded-status defect as the admin enumeration, in the scan that finds the
# backlog. Process substitution threw find's status away, so a scan that died partway
# swept what it had reached and reported a clean run over whatever it had not.
CASE15="${SANDBOX}/case15"
fixture_15() {
  make_system_dir "$TODAY"
  chmod 000 "$SYSTEM_ROOT"
}
DA_BACKUP_SYSTEM_KEEP_DAYS=7 run_hook case15 fixture_15
unset DA_BACKUP_SYSTEM_KEEP_DAYS
chmod 700 "${CASE15}/backup"

((HOOK_RC != 0)) \
  || fail "an unreadable backup root was swept as though it were empty"
grep -q 'could not list old directories' "${CASE15}/da-backup-s3.log" \
  || fail "the failed scan was not logged:"$'\n'"$(cat "${CASE15}/da-backup-s3.log")"
grep -q 'could not be scanned' "${CASE15}/mail.out" \
  || fail "a backlog that could not be enumerated must mail:"$'\n'"$(cat "${CASE15}/mail.out")"
echo "OK a sweep that cannot see the backlog says so"

##############################################################################
echo "== Proof 15: a sweep that cannot even start must not report success =="
##############################################################################
# The caller ignores this function's return value, so a `return 1` on its own changes
# nothing. The find-failure branch records itself in cleanup_failures; the mktemp branch
# did not, so a /tmp that is full or read-only skipped the backlog scan entirely and the
# run still logged cleanup complete. A host whose /tmp has run out of space is not a
# hypothetical here -- it is the same disk, in the state this hook exists to prevent.
#
# The admin directory is removed so upload_admin returns before its own mktemp, which
# isolates the failure to the sweep instead of tripping the earlier guard.
CASE17="${SANDBOX}/case17"
fixture_17() {
  rmdir "$ADMIN_DIR"
  make_system_dir "$TODAY"
  mkdir -p "${SYSTEM_ROOT}/07-04-26/mysql"
  : >"${SYSTEM_ROOT}/07-04-26/mysql/db.sql.gz"
  touch -t 202601010000 "${SYSTEM_ROOT}/07-04-26"
}
TMPDIR="${SANDBOX}/no-such-tmpdir" DA_BACKUP_SYSTEM_KEEP_DAYS=7 \
  run_hook case17 fixture_17
unset DA_BACKUP_SYSTEM_KEEP_DAYS

[[ -d "${CASE17}/backup/07-04-26" ]] \
  || fail "fixture did not hold: the backlog directory was swept, so mktemp did not fail"
((HOOK_RC != 0)) \
  || fail "the backlog was never scanned and the hook still reported success"
grep -q 'backlog was not scanned' "${CASE17}/da-backup-s3.log" \
  || fail "the skipped scan was not logged:"$'\n'"$(cat "${CASE17}/da-backup-s3.log")"
grep -q 'backlog scan skipped' "${CASE17}/mail.out" \
  || fail "a skipped backlog scan must mail:"$'\n'"$(cat "${CASE17}/mail.out")"
echo "OK a sweep that cannot allocate a temp file is reported, not swallowed"

echo
echo "PASS: offline backup cleanup proofs"
