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
: >"${dest}/user.stub.${user}.tar.zst"
# Simulate the volume filling while this account is being archived.
if [[ -n "${STUB_DA_CONSUME_TO_KB:-}" ]]; then
  echo "${STUB_DA_CONSUME_TO_KB}" >"${STUB_DF_KB_FILE}"
fi
sleep "${STUB_DA_SLEEP:-0}"
if [[ "${STUB_DRAIN:-1}" == "1" ]]; then rm -f "${dest}/user.stub.${user}.tar.zst"; fi
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
run_batch() {
  PATH="${SANDBOX}/bin:$PATH" \
    DA_BATCH_DA_BIN="${SANDBOX}/bin/directadmin" \
    DA_BATCH_USERS_DIR="${CASE}/users" \
    DA_BATCH_HOME="${CASE}/home" \
    DA_BACKUP_ADMIN_DIR="${CASE}/staging" \
    DA_BATCH_LOG="${CASE}/batch.log" \
    DA_BATCH_LOCK="${CASE}/batch.lock" \
    DA_BATCH_CONF="${CASE}/etc/conf" \
    DA_BATCH_WATCH_INTERVAL="${WATCH_INTERVAL:-1}" \
    DA_BATCH_DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-3}" \
    DA_BATCH_RESERVE_GB="${RESERVE_GB:-10}" \
    DA_BATCH_FLOOR_GB="${FLOOR_GB:-0}" \
    DA_BATCH_RATIO_PCT="${RATIO_PCT:-100}" \
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

echo
echo "----------------------------------------"
printf 'passed %d, failed %d\n' "$pass" "$fail"
((fail == 0)) || exit 1
echo "PASS: batching holds one account at a time, and says so when it cannot."
