#!/bin/bash
# Offline proof that da_backup_batch.sh keeps peak local disk usage to one account at a
# time. No box access, no DirectAdmin, no S3: the DirectAdmin binary, df and mail are all
# stubbed and every path is redirected into a temp sandbox.
#
# Every proof here is a way this script could quietly turn back into the all-at-once run
# it replaces, which is the thing that has left the primary with no account backups since
# 2026-07-02 (see aws/docs/2026-09-06-primary-outage.md). "It archived something" is not
# the property that matters; "it never held two archives at once, and it said so when it
# gave up" is.
#
# Usage (from repo root):
#   ./scripts/directadmin/prove_backup_batch.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${ROOT}/scripts/directadmin/da_backup_batch.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "ERROR: missing or non-executable script $SCRIPT" >&2
  exit 1
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0
fail=0

ok() {
  printf '  OK   %s\n' "$1"
  pass=$((pass + 1))
}

bad() {
  printf '  FAIL %s\n' "$1"
  fail=$((fail + 1))
}

assert() {
  local what="$1" cond="$2"
  if eval "$cond"; then ok "$what"; else bad "$what"; fi
}

mkdir -p "${SANDBOX}/bin"

# Stub DirectAdmin. Records the accounts it was asked for, writes an archive into the
# destination, and by default removes it again to stand in for the upload hook draining
# the staging directory. STUB_DRAIN=0 leaves it there, which is what an upload failure
# looks like from this script's side.
cat >"${SANDBOX}/bin/directadmin" <<'STUB'
#!/bin/bash
dest=""; user=""
for a in "$@"; do
  case "$a" in
    --destination=*) dest="${a#--destination=}" ;;
    --user=*) user="${a#--user=}" ;;
  esac
done
echo "$user" >>"${STUB_DA_CALLS}"
if [[ -n "${STUB_DA_RC:-}" && "${STUB_DA_RC}" != "0" ]]; then exit "${STUB_DA_RC}"; fi

# Stands in for the upload hook, which the real DirectAdmin invokes itself -- including
# when the archive step failed. That ordering is the whole point: the hook runs from
# inside this process, so it touches the staging directory before the batch script that
# killed this process gets control back. Only exercised when a proof sets STUB_FAKE_S3.
fake_hook() {
  [[ -n "${STUB_FAKE_S3:-}" ]] || return 0
  if [[ -n "${STUB_ABORT_SENTINEL:-}" && -f "${STUB_ABORT_SENTINEL}" ]]; then
    cat "${STUB_ABORT_SENTINEL}" >>"${STUB_FAKE_S3}/refused"
    return 0
  fi
  local f
  for f in "${dest}"/*.tar.zst; do
    [[ -f "$f" ]] || continue
    cp -f "$f" "${STUB_FAKE_S3}/" && rm -f "$f"
  done
}
trap 'fake_hook; exit 143' TERM

: >"${dest}/user.stub.${user}.tar.zst"
# Simulate the volume filling while this account is being archived.
if [[ -n "${STUB_DA_CONSUME_TO_KB:-}" ]]; then
  echo "${STUB_DA_CONSUME_TO_KB}" >"${STUB_DF_KB_FILE}"
fi
sleep "${STUB_DA_SLEEP:-0}"
if [[ -n "${STUB_FAKE_S3:-}" ]]; then
  fake_hook
elif [[ "${STUB_DRAIN:-1}" == "1" ]]; then
  rm -f "${dest}/user.stub.${user}.tar.zst"
fi
exit 0
STUB

# Stub df. Reports whatever free space the proof asked for, in the -P column layout both
# `df -Pk` and `df -Ph` callers parse.
cat >"${SANDBOX}/bin/df" <<'STUB'
#!/bin/bash
kb="$(cat "${STUB_DF_KB_FILE}" 2>/dev/null || echo 1000000000)"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/stub 209715200 104857600 ${kb} 50% /"
STUB

cat >"${SANDBOX}/bin/mail" <<'STUB'
#!/bin/bash
{ echo "mail $*"; cat; } >>"${STUB_MAIL}"
STUB

chmod +x "${SANDBOX}/bin/directadmin" "${SANDBOX}/bin/df" "${SANDBOX}/bin/mail"

# One account tree per proof run.
new_case() {
  local name="$1"
  CASE="${SANDBOX}/${name}"
  rm -rf "$CASE"
  mkdir -p "${CASE}/users" "${CASE}/home" "${CASE}/staging" "${CASE}/etc"
  STUB_DA_CALLS="${CASE}/da.calls"
  STUB_MAIL="${CASE}/mail.out"
  STUB_DF_KB_FILE="${CASE}/df.kb"
  : >"$STUB_DA_CALLS"
  : >"$STUB_MAIL"
  echo 1000000000 >"$STUB_DF_KB_FILE" # ~953 GB free unless a proof says otherwise
  printf 'HEALTH_ALERT_TO="ops@wbat.net"\n' >"${CASE}/etc/conf"
  export STUB_DA_CALLS STUB_MAIL STUB_DF_KB_FILE
}

add_account() {
  local user="$1" mb="$2"
  mkdir -p "${CASE}/users/${user}" "${CASE}/home/${user}"
  : >"${CASE}/users/${user}/user.conf"
  # Real bytes rather than truncate. A sparse file occupies no blocks, so du reports zero
  # for it, every account looks the same size, and the ordering proof below would pass on
  # whatever order the directory happened to be read in.
  dd if=/dev/zero of="${CASE}/home/${user}/data.bin" bs=1M count="$mb" status=none
}

# FLOOR_GB defaults to 0 here, unlike the script's own 8, because most proofs work in
# megabytes of fake free space. Leaving the real default on would put every one of them
# below the floor, so the run would abort for that reason instead of exercising whatever
# the proof was about -- and it would do so as a race against the stub finishing, which is
# how this suite first went intermittent. Proof 6 sets the floor explicitly.
#
# ACCOUNT_TIMEOUT defaults to 0, which disables the per-account limit, for the same
# reason: the real 21600s bound is not reachable in a suite that runs in seconds, and a
# proof that is not about the timeout should not be able to trip it. Proof 6b sets it.
#
# RUN_TIMEOUT wraps the script in `timeout`. Only the non-vacuity check for the
# per-account limit needs it: with that guard removed the script is supposed to hang
# forever, and a proof that hangs forever is not a proof.
#
# PEAK_COPIES_PCT is passed through only when a proof sets it. Defaulting it here the way
# the others are defaulted would mean the harness, not the script, decides how many copies
# of an archive DirectAdmin is assumed to need on disk at once -- and that assumption is
# the one the 2026-09-07 run got wrong, so every proof except the one that is explicitly
# about it runs against whatever the script itself believes.
run_batch() {
  local bound=() envs=()
  [[ -n "${RUN_TIMEOUT:-}" ]] && bound=(timeout "$RUN_TIMEOUT")
  envs=(
    "PATH=${SANDBOX}/bin:$PATH"
    "DA_BATCH_DA_BIN=${SANDBOX}/bin/directadmin"
    "DA_BATCH_USERS_DIR=${CASE}/users"
    "DA_BATCH_HOME=${CASE}/home"
    "DA_BACKUP_ADMIN_DIR=${CASE}/staging"
    "DA_BATCH_LOG=${CASE}/batch.log"
    "DA_BATCH_LOCK=${CASE}/batch.lock"
    "DA_BATCH_CONF=${CASE}/etc/conf"
    "DA_BATCH_WATCH_INTERVAL=${WATCH_INTERVAL:-1}"
    "DA_BATCH_DRAIN_TIMEOUT=${DRAIN_TIMEOUT:-3}"
    "DA_BATCH_ACCOUNT_TIMEOUT=${ACCOUNT_TIMEOUT:-0}"
    "DA_BATCH_KILL_GRACE=${KILL_GRACE:-5}"
    "DA_BATCH_RESERVE_GB=${RESERVE_GB:-10}"
    "DA_BATCH_FLOOR_GB=${FLOOR_GB:-0}"
    "DA_BATCH_RATIO_PCT=${RATIO_PCT:-100}"
    "DA_BATCH_ABORT_SENTINEL=${CASE}/abort-sentinel"
  )
  [[ -n "${PEAK_COPIES_PCT:-}" ]] && envs+=("DA_BATCH_PEAK_COPIES_PCT=${PEAK_COPIES_PCT}")
  env "${envs[@]}" \
    ${bound[@]+"${bound[@]}"} \
    "$SCRIPT" "$@" >"${CASE}/stdout" 2>"${CASE}/stderr"
  echo $?
}

echo "Proving da_backup_batch.sh against the ways it could refill the disk"
echo

# ---------------------------------------------------------------------------
echo "1. Accounts are archived one at a time, smallest first"
# Largest-first would mean a failure on the account least likely to fit takes every other
# account down with it -- and those are the ones that would have succeeded.
new_case one-at-a-time
add_account big 40
add_account small 1
add_account middle 8
rc="$(run_batch)"
order="$(tr '\n' ' ' <"$STUB_DA_CALLS" | sed 's/ $//')"
assert "exit 0 when every account succeeds" "[[ '$rc' == 0 ]]"
assert "ascending size order (got: ${order})" "[[ '$order' == 'small middle big' ]]"
assert "staging directory left empty" "[[ -z \"\$(find '${CASE}/staging' -type f)\" ]]"

# ---------------------------------------------------------------------------
echo
echo "2. Non-account entries in the users directory are not passed to --user="
# The primary's users directory contains a stray `fix.sh`. Handing that to DirectAdmin as
# an account name fails the invocation it is part of.
new_case stray-entries
add_account real 1
: >"${CASE}/users/fix.sh"
mkdir -p "${CASE}/users/halfdeleted" # a directory with no user.conf
rc="$(run_batch)"
assert "exit 0" "[[ '$rc' == 0 ]]"
assert "only the real account was attempted" "[[ \"\$(cat '$STUB_DA_CALLS')\" == 'real' ]]"

# ---------------------------------------------------------------------------
echo
echo "3. An account whose estimate does not fit is skipped, not attempted"
# This is the whole premise. Attempting it is what fills the volume. Scaled down: 20 MB
# free against a 40 MB account, which is the same arithmetic as 60 GB against `teller`.
new_case no-room
add_account fits 1
add_account toobig 40
echo $((20 * 1024)) >"$STUB_DF_KB_FILE" # 20 MB free
RESERVE_GB=0
rc="$(run_batch)"
unset RESERVE_GB
assert "exit 1 when an account is skipped" "[[ '$rc' == 1 ]]"
assert "the account that fits was archived" "grep -qx fits '$STUB_DA_CALLS'"
assert "the oversized account was never attempted" "! grep -qx toobig '$STUB_DA_CALLS'"
assert "the skip is mailed, naming the account" "grep -q 'toobig' '$STUB_MAIL'"
assert "the mail says these accounts have no backup" "grep -qi 'no current backup' '$STUB_MAIL'"

# ---------------------------------------------------------------------------
echo
echo "3b. The reserve is headroom, not slack: an account that fits exactly is still skipped"
# Without this the last account always "fits", right up to zero bytes free, and everything
# else on the box -- MySQL, Exim, the journal -- is what runs out of room instead.
new_case reserve
add_account snug 1
echo $((1048576 + 512)) >"$STUB_DF_KB_FILE" # a hair over 1 GB free
RESERVE_GB=1
rc="$(run_batch)"
unset RESERVE_GB
assert "exit 1" "[[ '$rc' == 1 ]]"
assert "the account is skipped even though the archive itself would fit" "! grep -qx snug '$STUB_DA_CALLS'"

# ---------------------------------------------------------------------------
echo
echo "3c. Already below the floor: nothing is started, rather than started and killed"
# The watchdog would catch this a second later, but starting a backup that was never
# viable logs it as a failure, writes a partial archive, and then deletes it again.
new_case below-floor
add_account any 1
echo $((4 * 1048576)) >"$STUB_DF_KB_FILE" # 4 GB free against an 8 GB floor
FLOOR_GB=8
RESERVE_GB=0
rc="$(run_batch)"
unset FLOOR_GB RESERVE_GB
assert "exit 1" "[[ '$rc' == 1 ]]"
assert "nothing was started" "[[ ! -s '$STUB_DA_CALLS' ]]"
assert "the log says it is below the floor, not that a backup failed" "grep -q 'already below the .* floor' '${CASE}/batch.log'"
assert "no partial archive was created and removed" "! grep -q 'partial archive' '${CASE}/batch.log'"

# ---------------------------------------------------------------------------
echo
echo "3d. The gate reserves room for the copies DirectAdmin keeps, not for one archive"
# The 2026-09-07 regression. DirectAdmin assembles backup/home.tar.zst and the .sql dumps
# inside the destination and only then tars them into the final archive, in the same
# directory -- so the parts and the archive built from them are both on disk at once.
# Measured on the primary: wbatnet, 10.50 GiB home, 6.72 GiB archive, 12.69 GiB peak, which
# is 189% of the archive. A gate that compares one archive against free space passes
# accounts the volume cannot hold, which is what it did to tellerstec: 33.4 GiB home waved
# through against 59.8 GiB free, then killed at the floor with 51.8 GiB consumed.
#
# Scaled down here: 40 MB of home against 60 MB free. One archive fits. Two do not.
new_case peak-copies
add_account doubled 40
echo $((60 * 1024)) >"$STUB_DF_KB_FILE"
RESERVE_GB=0
rc="$(run_batch)"
unset RESERVE_GB
assert "exit 1" "[[ '$rc' == 1 ]]"
assert "the account is skipped even though a single archive would fit" "! grep -qx doubled '$STUB_DA_CALLS'"
assert "the log calls it a peak need rather than an archive size" "grep -q 'peak need is about' '${CASE}/batch.log'"
assert "the log says why one archive is not the number that matters" "grep -q 'assembled parts and the archive' '${CASE}/batch.log'"
assert "the mail reports the home size next to the peak" "grep -q 'peak need' '$STUB_MAIL'"

# ---------------------------------------------------------------------------
echo
echo "4. A staging directory that is not empty stops the run before it starts"
# Leftovers mean an earlier upload failed. Archiving on top of them is the all-at-once
# behaviour arriving by the back door.
new_case dirty-staging
add_account a 1
: >"${CASE}/staging/left-over-from-yesterday.tar.zst"
rc="$(run_batch)"
assert "exit 1" "[[ '$rc' == 1 ]]"
assert "nothing was archived" "[[ ! -s '$STUB_DA_CALLS' ]]"
assert "the leftover file is left alone" "[[ -f '${CASE}/staging/left-over-from-yesterday.tar.zst' ]]"
assert "it is mailed" "grep -q 'already contained' '$STUB_MAIL'"

# ---------------------------------------------------------------------------
echo
echo "5. The next account waits for the upload hook to clear the previous one"
new_case drain-required
add_account first 1
add_account second 2
export STUB_DRAIN=0
DRAIN_TIMEOUT=2
rc="$(run_batch)"
unset STUB_DRAIN
unset DRAIN_TIMEOUT
assert "exit 1 when the hook never drains" "[[ '$rc' == 1 ]]"
assert "the first account was archived" "grep -qx first '$STUB_DA_CALLS'"
assert "the second was NOT started on top of it" "! grep -qx second '$STUB_DA_CALLS'"
assert "the log names the undrained directory" "grep -q 'has not cleared it' '${CASE}/batch.log'"

# ---------------------------------------------------------------------------
echo
echo "6. Crossing the free-space floor kills the backup and deletes the partial"
# The estimate is the guess; the floor is the fact. A partial archive left behind is worse
# than no archive, because the hook would upload it and record it as a successful backup.
new_case floor
add_account victim 1
export STUB_DA_SLEEP=4 STUB_DA_CONSUME_TO_KB=$((2 * 1048576)) STUB_DRAIN=0
FLOOR_GB=8
WATCH_INTERVAL=1
rc="$(run_batch)"
unset STUB_DA_SLEEP STUB_DA_CONSUME_TO_KB STUB_DRAIN
unset FLOOR_GB WATCH_INTERVAL
assert "exit 1" "[[ '$rc' == 1 ]]"
assert "the floor breach is logged" "grep -q 'below the .* GB floor' '${CASE}/batch.log'"
assert "the partial archive was removed, not left for the hook" "[[ -z \"\$(find '${CASE}/staging' -type f)\" ]]"
assert "the removal is logged rather than silent" "grep -q 'partial archive' '${CASE}/batch.log'"

# ---------------------------------------------------------------------------
echo
echo "6b. A backup that hangs without filling the disk is bounded, killed and reported"
# The floor only fires when the volume is being consumed. An rclone that stops making
# progress against S3, or DirectAdmin blocked on a MySQL lock, hangs at constant free
# space -- and `wait` on its own never returns. That run holds the batch lock, so every
# later cron invocation takes the "another run holds it" branch and exits 0: account
# backups stop completely and nothing mails. That is the exact silent-failure shape this
# whole script exists to end, so the hang has to be bounded.
new_case hang
add_account stuck 1
export STUB_DA_SLEEP=13137 STUB_DRAIN=0
ACCOUNT_TIMEOUT=2
KILL_GRACE=5
WATCH_INTERVAL=1
hang_start="$(date +%s)"
rc="$(run_batch)"
hang_elapsed=$(($(date +%s) - hang_start))
unset STUB_DA_SLEEP STUB_DRAIN
unset ACCOUNT_TIMEOUT KILL_GRACE WATCH_INTERVAL
assert "exit 1" "[[ '$rc' == 1 ]]"
assert "the run returned rather than waiting out the hang (${hang_elapsed}s)" "(( hang_elapsed < 60 ))"
assert "the log names the per-account limit" "grep -q 'per-account limit' '${CASE}/batch.log'"
assert "it is not misreported as a floor breach" "! grep -q 'below the .* GB floor' '${CASE}/batch.log'"
assert "the archive the killed run left behind was removed" "[[ -z \"\$(find '${CASE}/staging' -type f)\" ]]"
assert "the incomplete run is mailed, naming the account" "grep -q 'stuck' '$STUB_MAIL'"
assert "the mail says why, not just that it failed" "grep -q 'per-account limit' '$STUB_MAIL'"

# ---------------------------------------------------------------------------
echo
echo "6c. A killed backup reaches the upload hook already marked as unusable"
# What actually happened on the first real run, 2026-09-07, on tellerstec. The floor fired
# and the watchdog killed the compressor -- and DirectAdmin responded to being killed by
# running the upload hook, from inside the invocation the batch script was still waiting
# on. The hook uploaded the 20 GiB truncated archive, rclone confirmed S3 held the same
# bytes, the hook deleted the local copy, and only then did `wait` return here. The
# cleanup below found an empty directory and reported a clean kill, while S3 had gained a
# corrupt archive under the name a good one would have had.
#
# Deleting the partial after the child exits cannot fix that; the hook gets there first.
# So the watchdog writes a sentinel before it signals anything, and the hook refuses. The
# stub models the ordering faithfully: its TERM handler is the hook.
new_case abort-sentinel
add_account victim 1
mkdir -p "${CASE}/fake-s3"
export STUB_FAKE_S3="${CASE}/fake-s3" STUB_ABORT_SENTINEL="${CASE}/abort-sentinel"
export STUB_DA_SLEEP=4 STUB_DA_CONSUME_TO_KB=$((2 * 1048576))
FLOOR_GB=8
WATCH_INTERVAL=1
rc="$(run_batch)"
unset STUB_FAKE_S3 STUB_ABORT_SENTINEL STUB_DA_SLEEP STUB_DA_CONSUME_TO_KB
unset FLOOR_GB WATCH_INTERVAL
assert "exit 1" "[[ '$rc' == 1 ]]"
assert "the hook ran, and refused" "[[ -s '${CASE}/fake-s3/refused' ]]"
assert "the sentinel named the account and the reason" "grep -q 'victim killed' '${CASE}/fake-s3/refused'"
assert "no partial archive reached S3" "[[ -z \"\$(find '${CASE}/fake-s3' -name '*.tar.zst')\" ]]"
assert "the partial was removed from staging" "[[ -z \"\$(find '${CASE}/staging' -type f)\" ]]"
assert "the sentinel is cleared, so it cannot block the next run" "[[ ! -f '${CASE}/abort-sentinel' ]]"

# ---------------------------------------------------------------------------
echo
echo "6d. A sentinel left behind by an earlier run does not block a good backup"
# The other half of the same mechanism. A run killed before it reached its own cleanup --
# or the machine losing power mid-backup -- leaves the sentinel set. If nothing clears it,
# the hook refuses every upload from then on, the staging directory never drains, and
# account backups stop as completely as they did for the two months before this script
# existed. Same silent failure, arrived at through the fix.
new_case stale-sentinel
add_account fine 1
mkdir -p "${CASE}/fake-s3"
echo "someone-else killed 2026-09-06T01:00:00-04:00: floor 8388608" >"${CASE}/abort-sentinel"
export STUB_FAKE_S3="${CASE}/fake-s3" STUB_ABORT_SENTINEL="${CASE}/abort-sentinel"
DRAIN_TIMEOUT=4
WATCH_INTERVAL=1
rc="$(run_batch)"
unset STUB_FAKE_S3 STUB_ABORT_SENTINEL
unset DRAIN_TIMEOUT WATCH_INTERVAL
assert "exit 0" "[[ '$rc' == 0 ]]"
assert "the account was archived" "grep -qx fine '$STUB_DA_CALLS'"
assert "the hook uploaded rather than refusing" "[[ ! -e '${CASE}/fake-s3/refused' ]]"
assert "the archive reached S3" "[[ -n \"\$(find '${CASE}/fake-s3' -name '*.tar.zst')\" ]]"
assert "staging drained" "[[ -z \"\$(find '${CASE}/staging' -type f)\" ]]"

# ---------------------------------------------------------------------------
echo
echo "6e. A sentinel that cannot be written stops the run before it starts"
# A guard that is silently absent is worse than no guard, because the run looks identical
# to a working one right up to the first floor breach -- and that is the run that uploads
# a truncated archive to S3 and reports success.
new_case unwritable-sentinel
add_account any 1
rc="$(env "PATH=${SANDBOX}/bin:$PATH" \
  "DA_BATCH_DA_BIN=${SANDBOX}/bin/directadmin" \
  "DA_BATCH_USERS_DIR=${CASE}/users" \
  "DA_BATCH_HOME=${CASE}/home" \
  "DA_BACKUP_ADMIN_DIR=${CASE}/staging" \
  "DA_BATCH_LOG=${CASE}/batch.log" \
  "DA_BATCH_LOCK=${CASE}/batch.lock" \
  "DA_BATCH_CONF=${CASE}/etc/conf" \
  "DA_BATCH_FLOOR_GB=0" \
  "DA_BATCH_ABORT_SENTINEL=${CASE}/no-such-directory/abort" \
  "$SCRIPT" >/dev/null 2>&1
echo $?)"
assert "exit 1" "[[ '$rc' == 1 ]]"
assert "nothing was archived" "[[ ! -s '$STUB_DA_CALLS' ]]"
assert "the log says the sentinel is why, not that a backup failed" "grep -q 'cannot write the abort sentinel' '${CASE}/batch.log'"

# ---------------------------------------------------------------------------
echo
echo "7. A DirectAdmin failure stops the run and is reported"
new_case da-fails
add_account a 1
add_account b 2
export STUB_DA_RC=3
rc="$(run_batch)"
unset STUB_DA_RC
assert "exit 1" "[[ '$rc' == 1 ]]"
assert "the exit status is logged" "grep -q 'exited 3' '${CASE}/batch.log'"
assert "later accounts were not attempted" "[[ \$(grep -c . '$STUB_DA_CALLS') -eq 1 ]]"
assert "the mail says where the run stopped" "grep -q 'run stopped at' '$STUB_MAIL'"

# ---------------------------------------------------------------------------
echo
echo "8. --list and --dry-run touch nothing"
new_case read-only-modes
add_account a 1
add_account b 2
rc="$(run_batch --list)"
assert "--list exits 0" "[[ '$rc' == 0 ]]"
assert "--list archives nothing" "[[ ! -s '$STUB_DA_CALLS' ]]"
assert "--list reports both accounts" "[[ \$(grep -cE '^(a|b) ' '${CASE}/stdout') -eq 2 ]]"
rc="$(run_batch --dry-run)"
assert "--dry-run exits 0" "[[ '$rc' == 0 ]]"
assert "--dry-run archives nothing" "[[ ! -s '$STUB_DA_CALLS' ]]"
assert "--dry-run says what it would do" "grep -q 'would back up' '${CASE}/batch.log'"

# ---------------------------------------------------------------------------
echo
echo "9. --user= limits the run to the named accounts"
new_case only-user
add_account a 1
add_account b 2
add_account c 3
rc="$(run_batch --user=b)"
assert "exit 0" "[[ '$rc' == 0 ]]"
assert "only the named account ran" "[[ \"\$(cat '$STUB_DA_CALLS')\" == 'b' ]]"

# ---------------------------------------------------------------------------
echo
echo "10. A lock held for minutes is skipped quietly; one held since yesterday is reported"
# The quiet skip is the right answer to an overlap and the wrong answer to a holder that
# never lets go: nothing else in the script runs, so the daily schedule would report
# success every night while no account was backed up.
new_case stale-lock
add_account a 1
: >"${CASE}/batch.lock"
flock -n "${CASE}/batch.lock" -c 'sleep 60' &
holder=$!
# Wait for the holder to actually own it rather than guessing at a sleep.
held=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! flock -n "${CASE}/batch.lock" -c true 2>/dev/null; then
    held=1
    break
  fi
  sleep 0.2
done
assert "the proof's own stand-in holder took the lock" "(( held == 1 ))"

printf '%s\n' "$(date +%s)" >"${CASE}/batch.lock.started"
rc="$(run_batch)"
assert "exit 0 for an overlap of seconds" "[[ '$rc' == 0 ]]"
assert "nothing was archived behind the holder's back" "[[ ! -s '$STUB_DA_CALLS' ]]"
assert "a brief overlap is not mailed" "[[ ! -s '$STUB_MAIL' ]]"

# Same holder, but it has been there since yesterday. The default STALE_LOCK_SEC of a day
# is deliberately left alone here so the proof exercises the shipped threshold.
printf '%s\n' "$(($(date +%s) - 200000))" >"${CASE}/batch.lock.started"
: >"$STUB_MAIL"
rc="$(run_batch)"
assert "exit 1 once the holder is older than a whole schedule cycle" "[[ '$rc' == 1 ]]"
assert "the stuck holder is mailed" "grep -qi 'stuck' '$STUB_MAIL'"
assert "the mail says no account was backed up" "grep -q 'has not released it' '$STUB_MAIL'"
assert "it still archives nothing" "[[ ! -s '$STUB_DA_CALLS' ]]"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# ---------------------------------------------------------------------------
echo
echo "11. A selection that resolves to no account is a failure, not a clean run"
# The backup loop reads from ordered_users, so an empty selection is not an error to it --
# it is a loop body that never runs. Without a check the run reaches the summary with
# nothing failed and nothing skipped and exits 0: a report of success for a night on which
# no account was backed up, which is the exact condition this whole script exists to end.
new_case no-such-user
add_account real 1
rc="$(run_batch --user=raal)"
assert "a typo in --user= does not exit 0" "[[ '$rc' == 2 ]]"
assert "nothing was archived" "[[ ! -s '$STUB_DA_CALLS' ]]"
assert "the log names the account that does not exist" "grep -q 'no such account' '${CASE}/batch.log'"
assert "the log lists what does exist, so the typo is obvious" "grep -q 'known accounts are: real' '${CASE}/batch.log'"
assert "it is mailed rather than left to cron's stderr" "grep -q 'does not exist' '$STUB_MAIL'"

# The same typo through --list is an argument error too, but a person investigating should
# not be mailed about the command they just typed.
new_case no-such-user-list
add_account real 1
rc="$(run_batch --list --user=raal)"
assert "--list rejects it as well" "[[ '$rc' == 2 ]]"
assert "--list does not mail" "[[ ! -s '$STUB_MAIL' ]]"

# A users directory that has moved, been renamed, or is unreadable to the user cron runs
# this as. Silent, affects every account at once, and cron would keep reporting success.
new_case no-accounts
rc="$(run_batch)"
assert "an empty users directory exits non-zero" "[[ '$rc' == 1 ]]"
assert "the log says no accounts were found" "grep -q 'no accounts found under' '${CASE}/batch.log'"
assert "it is mailed" "grep -q 'found no accounts' '$STUB_MAIL'"
assert "the mail says this is not an empty server" "grep -q 'not an empty server' '$STUB_MAIL'"

# ---------------------------------------------------------------------------
# Non-vacuity. Each guard is removed from a copy of the script and the matching proof is
# re-run: if it still passes, the proof was not testing the guard.
echo
echo "Non-vacuity checks (each guard removed; the matching proof must then fail)"

NV="${SANDBOX}/nv.sh"

nv_check() {
  local label="$1" expectation="$2"
  if eval "$expectation"; then
    ok "without the guard, ${label}"
  else
    bad "without the guard, ${label} -- the proof above passes vacuously"
  fi
}

# NV1: drop the pre-flight headroom gate.
sed 's/if ((now_kb < est_kb + reserve_kb)); then/if false; then/' "$SCRIPT" >"$NV"
chmod +x "$NV"
new_case nv-no-room
add_account fits 1
add_account toobig 40
echo $((20 * 1024)) >"$STUB_DF_KB_FILE"
SCRIPT_SAVE="$SCRIPT"
SCRIPT="$NV"
RESERVE_GB=0
run_batch >/dev/null
unset RESERVE_GB
SCRIPT="$SCRIPT_SAVE"
nv_check "the oversized account is attempted" "grep -qx toobig '$STUB_DA_CALLS'"

# NV2: drop the drain wait between accounts.
sed 's/if ! wait_for_drain; then/if false; then/' "$SCRIPT" >"$NV"
chmod +x "$NV"
new_case nv-drain
add_account first 1
add_account second 2
SCRIPT_SAVE="$SCRIPT"
SCRIPT="$NV"
export STUB_DRAIN=0
DRAIN_TIMEOUT=2
run_batch >/dev/null
unset STUB_DRAIN DRAIN_TIMEOUT
SCRIPT="$SCRIPT_SAVE"
nv_check "the second account starts while the first is still staged" "grep -qx second '$STUB_DA_CALLS'"

# NV3: keep the floor kill but stop deleting the partial archive.
sed 's/      find "$ADMIN_DIR" -type f -delete 2>\/dev\/null/      :/' "$SCRIPT" >"$NV"
chmod +x "$NV"
new_case nv-partial
add_account victim 1
SCRIPT_SAVE="$SCRIPT"
SCRIPT="$NV"
export STUB_DA_SLEEP=4 STUB_DA_CONSUME_TO_KB=$((2 * 1048576)) STUB_DRAIN=0
FLOOR_GB=8
WATCH_INTERVAL=1
run_batch >/dev/null
unset STUB_DA_SLEEP STUB_DA_CONSUME_TO_KB STUB_DRAIN FLOOR_GB WATCH_INTERVAL
SCRIPT="$SCRIPT_SAVE"
nv_check "the partial archive is left for the hook to upload" "[[ -n \"\$(find '${CASE}/staging' -type f)\" ]]"

# NV3b: keep the whole kill path but stop writing the abort sentinel, so the hook is not
# told anything. This is the 2026-09-07 failure reproduced: the partial reaches S3.
sed 's|>"$ABORT_SENTINEL" 2>/dev/null|>/dev/null 2>\&1|' "$SCRIPT" >"$NV"
chmod +x "$NV"
new_case nv-sentinel
add_account victim 1
mkdir -p "${CASE}/fake-s3"
SCRIPT_SAVE="$SCRIPT"
SCRIPT="$NV"
export STUB_FAKE_S3="${CASE}/fake-s3" STUB_ABORT_SENTINEL="${CASE}/abort-sentinel"
export STUB_DA_SLEEP=4 STUB_DA_CONSUME_TO_KB=$((2 * 1048576))
FLOOR_GB=8
WATCH_INTERVAL=1
run_batch >/dev/null
unset STUB_FAKE_S3 STUB_ABORT_SENTINEL STUB_DA_SLEEP STUB_DA_CONSUME_TO_KB
unset FLOOR_GB WATCH_INTERVAL
SCRIPT="$SCRIPT_SAVE"
nv_check "the truncated archive is uploaded to S3 by the hook" "[[ -n \"\$(find '${CASE}/fake-s3' -name '*.tar.zst')\" ]]"

# NV3c: keep the sentinel but stop clearing the stale one before each account, so a
# sentinel left by any earlier run blocks every upload from then on.
sed 's|^  rm -f "$ABORT_SENTINEL" 2>/dev/null .. true$|  :|' "$SCRIPT" >"$NV"
chmod +x "$NV"
new_case nv-stale-sentinel
add_account fine 1
mkdir -p "${CASE}/fake-s3"
echo "someone-else killed 2026-09-06T01:00:00-04:00: floor 8388608" >"${CASE}/abort-sentinel"
SCRIPT_SAVE="$SCRIPT"
SCRIPT="$NV"
export STUB_FAKE_S3="${CASE}/fake-s3" STUB_ABORT_SENTINEL="${CASE}/abort-sentinel"
DRAIN_TIMEOUT=4
WATCH_INTERVAL=1
run_batch >/dev/null
unset STUB_FAKE_S3 STUB_ABORT_SENTINEL DRAIN_TIMEOUT WATCH_INTERVAL
SCRIPT="$SCRIPT_SAVE"
nv_check "a stale sentinel makes the hook refuse a good archive" "[[ -s '${CASE}/fake-s3/refused' ]]"

# NV3d: drop the doubling from the peak estimate, leaving the archive-only arithmetic the
# 2026-09-07 run used, and the account the volume cannot hold is attempted again.
new_case nv-peak-copies
add_account doubled 40
echo $((60 * 1024)) >"$STUB_DF_KB_FILE"
RESERVE_GB=0
PEAK_COPIES_PCT=100
run_batch >/dev/null
unset RESERVE_GB PEAK_COPIES_PCT
nv_check "the account that needs two archives' worth of room is attempted" "grep -qx doubled '$STUB_DA_CALLS'"

# NV4: drop the per-account time limit and let the same hang run unbounded. The outer
# `timeout` is what stands in for the guard: rc 124 means the script never gave up on its
# own, which is the state in which the batch lock is held forever and nothing mails.
sed 's/      if ((ACCOUNT_TIMEOUT_SEC > 0 \&\& watched >= ACCOUNT_TIMEOUT_SEC)); then/      if false; then/' "$SCRIPT" >"$NV"
chmod +x "$NV"
new_case nv-hang
add_account stuck 1
SCRIPT_SAVE="$SCRIPT"
SCRIPT="$NV"
export STUB_DA_SLEEP=13139 STUB_DRAIN=0
ACCOUNT_TIMEOUT=2
KILL_GRACE=5
WATCH_INTERVAL=1
RUN_TIMEOUT=15
nv_rc="$(run_batch)"
unset STUB_DA_SLEEP STUB_DRAIN
unset ACCOUNT_TIMEOUT KILL_GRACE WATCH_INTERVAL RUN_TIMEOUT
SCRIPT="$SCRIPT_SAVE"
nv_check "the hung backup runs on unbounded and nothing is ever reported" "[[ '$nv_rc' == 124 ]]"
# `timeout` signals the script, not the stub it orphaned. Reap it so the sandbox teardown
# does not leave a stray sleep behind for the rest of the CI job.
pkill -f 'sleep 13139' 2>/dev/null || true

# NV5: drop the stale-holder check, so every run that finds the lock taken exits 0 quietly
# however long it has been taken -- the branch that turns one wedged run into weeks of
# silence.
sed 's/if stale_lock_holder "$held_for"; then/if false; then/' "$SCRIPT" >"$NV"
chmod +x "$NV"
new_case nv-stale-lock
add_account a 1
: >"${CASE}/batch.lock"
flock -n "${CASE}/batch.lock" -c 'sleep 60' &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  flock -n "${CASE}/batch.lock" -c true 2>/dev/null || break
  sleep 0.2
done
printf '%s\n' "$(($(date +%s) - 200000))" >"${CASE}/batch.lock.started"
SCRIPT_SAVE="$SCRIPT"
SCRIPT="$NV"
nv_rc="$(run_batch)"
SCRIPT="$SCRIPT_SAVE"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
nv_check "a holder stuck since yesterday is skipped as if it were an overlap" \
  "[[ '$nv_rc' == 0 && ! -s '$STUB_MAIL' ]]"

# NV6 and NV7: an empty selection is refused in two places -- once up front, naming what
# was wrong, and once at the summary as a backstop for an enumeration that changes under
# the run. Removing either alone leaves the other catching it, which is the point of
# having both, so each check here removes the pair to show what they are jointly holding
# back: a run that backed up nothing and exited 0.
NV_EMPTY_SED=(
  -e 's/if ((${#done_users\[@\]} + ${#skipped_users\[@\]} + ${#failed_users\[@\]} == 0)); then/if false; then/'
)

sed "${NV_EMPTY_SED[@]}" -e 's/if ((${#all_accounts\[@\]} == 0)); then/if false; then/' "$SCRIPT" >"$NV"
chmod +x "$NV"
new_case nv-no-accounts
SCRIPT_SAVE="$SCRIPT"
SCRIPT="$NV"
nv_rc="$(run_batch)"
SCRIPT="$SCRIPT_SAVE"
nv_check "a users directory with no accounts in it reports a successful run" \
  "[[ '$nv_rc' == 0 && ! -s '$STUB_MAIL' ]]"

sed "${NV_EMPTY_SED[@]}" -e 's/if ((${#unknown_users\[@\]} > 0)); then/if false; then/' "$SCRIPT" >"$NV"
chmod +x "$NV"
new_case nv-no-such-user
add_account real 1
SCRIPT_SAVE="$SCRIPT"
SCRIPT="$NV"
nv_rc="$(run_batch --user=raal)"
SCRIPT="$SCRIPT_SAVE"
nv_check "a typo in --user= reports a successful run that backed up nothing" \
  "[[ '$nv_rc' == 0 && ! -s '$STUB_DA_CALLS' && ! -s '$STUB_MAIL' ]]"

echo
echo "----------------------------------------"
printf 'passed %d, failed %d\n' "$pass" "$fail"
((fail == 0)) || exit 1
echo "PASS: batching holds one account at a time, and says so when it cannot."
