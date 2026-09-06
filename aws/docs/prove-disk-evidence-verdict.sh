#!/bin/bash
# Offline proof for disk-full-collect-evidence.sh: the section splitter and the verdict
# logic, exercised end to end with a stubbed aws CLI. No credentials, no server.
#
# This exists because the first version of that script shipped a bug only an end-to-end
# test could catch: the section markers are `===SECTION host===`, so awk's $2 is
# "host===" rather than "host". Every capture file was misnamed and the END marker never
# matched, while unit-style fixtures written straight to section-*.txt sailed through.
#
# The verdict is the part that must not rot. A diagnostic that can only agree with the
# hypothesis it was written for is worse than no diagnostic, so proof 2 asserts it
# refutes, and proof 3 asserts it distinguishes "no hook installed" from "stale hook".
#
# Usage (from repo root):
#   ./aws/docs/prove-disk-evidence-verdict.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${ROOT}/aws/docs/disk-full-collect-evidence.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "ERROR: missing or non-executable $SCRIPT" >&2
  exit 1
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "${SANDBOX}/bin"
cat >"${SANDBOX}/bin/aws" <<'STUB'
#!/bin/bash
args="$*"
case "$args" in
  *"describe-instances"*"tag:Name"*) echo "i-0118b8ede80b52ef7" ;;
  *"describe-instances"*"--instance-ids"*) echo '{"State":"running","Type":"t3a.large"}' ;;
  *"get-console-output"*) cat "${STUB_CONSOLE:-/dev/null}" ;;
  *"get-metric-statistics"*) echo '{"Datapoints":[]}' ;;
  *"send-command"*) echo "cmd-stub-1" ;;
  *"wait command-executed"*) exit 0 ;;
  *"get-command-invocation"*StandardErrorContent*) echo "" ;;
  *"get-command-invocation"*StandardOutputContent*) cat "${STUB_REMOTE_OUT}" ;;
  *) echo "STUB: unhandled aws call: $args" >&2; exit 1 ;;
esac
STUB
chmod +x "${SANDBOX}/bin/aws"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# A capture as the on-box script really emits it: one marker stream, not pre-split files.
# host_full=yes|no  backups=big|small  hook=missing|old|current
make_remote_out() {
  local disk="$1" backups="$2" hook="$3" out="$4"
  {
    echo "===SECTION host==="
    echo "2026-09-06T15:10:00Z"
    echo "server.wbat.net"
    echo "===SECTION df==="
    echo "Filesystem     1024-blocks      Used Available Capacity Mounted on"
    if [[ "$disk" == "full" ]]; then
      echo "/dev/nvme0n1p1   206292968 203000000   3292968      99% /"
    else
      echo "/dev/nvme0n1p1   206292968 120000000  86292968      59% /"
    fi
    echo "Filesystem       Inodes   IUsed    IFree IUse% Mounted on"
    echo "/dev/nvme0n1p1 13107200  520000 12587200    4% /"
    echo "===SECTION backup_usage==="
    if [[ "$backups" == "big" ]]; then
      printf '41943040\t/home/admin_backups\n20971520\t/home/backup\n'
    else
      printf '204800\t/home/admin_backups\n307200\t/home/backup\n'
    fi
    echo "===SECTION top_dirs==="
    printf '110000000\t/var/lib/mysql\n'
    echo "===SECTION backup_listing==="
    echo "--- /home/backup ---"
    [[ "$backups" == "big" ]] && echo "drwx------ 5 root root 4096 Sep  5 05:31 09-05-26"
    echo "===SECTION hook_log==="
    if [[ "$backups" == "big" ]]; then
      echo "2026-09-05T05:40:11-04:00 upload system backup /home/backup/09-05-26 -> s3backup:.../server/2026-09-05/"
      echo "2026-09-05T06:02:55-04:00 cleaned local system backup dirs under /home/backup"
    else
      echo "2026-09-06T05:40:11-04:00 OK backup upload and local cleanup complete"
    fi
    echo "===SECTION enospc==="
    if [[ "$disk" == "full" ]]; then
      echo "Sep  6 05:52:18 server mysqld[1123]: [ERROR] InnoDB: Write to file ./ibtmp1 failed: No space left on device"
    fi
    echo "===SECTION services==="
    if [[ "$disk" == "full" ]]; then
      printf 'mysqld=failed\nexim=failed\nnginx=active\n'
    else
      printf 'mysqld=active\nexim=active\nnginx=active\n'
    fi
    echo "===SECTION installed_hashes==="
    case "$hook" in
      missing) echo "MISSING /usr/local/directadmin/scripts/custom/all_backups_post.sh" ;;
      current) echo "$(sha256sum "${ROOT}/scripts/directadmin/all_backups_post.sh" | awk '{print $1}')  /usr/local/directadmin/scripts/custom/all_backups_post.sh" ;;
      *) echo "0000000000000000000000000000000000000000000000000000000000000000  /usr/local/directadmin/scripts/custom/all_backups_post.sh" ;;
    esac
    echo "===SECTION rclone_running==="
    echo "(none)"
    echo "===SECTION END==="
  } >"$out"
}

run_capture() { # disk backups hook casename -> sets OUT_DIR, RC, REPORT
  local disk="$1" backups="$2" hook="$3" case_name="$4"
  local remote="${SANDBOX}/${case_name}-remote.txt"
  OUT_DIR="${SANDBOX}/${case_name}"
  make_remote_out "$disk" "$backups" "$hook" "$remote"

  set +e
  REPORT="$(env PATH="${SANDBOX}/bin:${PATH}" \
    STUB_REMOTE_OUT="$remote" STUB_CONSOLE=/dev/null \
    "$SCRIPT" --out "$OUT_DIR" 2>&1)"
  RC=$?
  set -e
}

##############################################################################
echo "== Proof 1: a full disk with large local backups must CONFIRM, exit 0 =="
##############################################################################
run_capture full big old case1

# The splitter is the half that unit-style fixtures cannot check.
for s in host df backup_usage hook_log enospc services installed_hashes; do
  [[ -f "${OUT_DIR}/section-${s}.txt" ]] \
    || fail "section file section-${s}.txt not created -- the marker splitter is broken"
done
if compgen -G "${OUT_DIR}/section-*===*" >/dev/null; then
  fail "section files kept the '===' suffix: awk \$2 is 'host===', not 'host'"
fi
[[ -f "${OUT_DIR}/section-END.txt" ]] && fail "END marker was treated as a section"

grep -q 'Full disk explains the outage:      CONFIRMED' <<<"$REPORT" \
  || fail "expected the full-disk verdict to be CONFIRMED:"$'\n'"$REPORT"
grep -q 'Backup cleanup is why it filled:    CONFIRMED' <<<"$REPORT" \
  || fail "expected the backup-cause verdict to be CONFIRMED"
grep -q 'Defect 2 signature present' <<<"$REPORT" \
  || fail "defect 2 signature (claims cleaned, dirs still present) not detected"
((RC == 0)) || fail "expected exit 0 on a confirming capture, got ${RC}"
echo "OK sections split correctly, verdict CONFIRMED, defect 2 identified"

##############################################################################
echo "== Proof 2: a healthy disk with tiny backups must REFUTE, exit 1 =="
##############################################################################
# The point of the exercise. A diagnostic that cannot disagree proves nothing.
run_capture ok small current case2

grep -q 'Full disk explains the outage:      NOT SUPPORTED' <<<"$REPORT" \
  || fail "expected NOT SUPPORTED for a 59%-used volume with no ENOSPC:"$'\n'"$REPORT"
grep -q 'Backup cleanup is why it filled:    NOT SUPPORTED' <<<"$REPORT" \
  || fail "expected NOT SUPPORTED when backups are 0.5 GB"
grep -q "top_dirs" <<<"$REPORT" \
  || fail "a refutation must point at the real consumer instead of stopping at 'no'"
((RC == 1)) || fail "expected exit 1 (contradicted) on a refuting capture, got ${RC}"
echo "OK verdict refutes the hypothesis and redirects to the real consumer"

##############################################################################
echo "== Proof 3: a missing hook must be called out, not reported as 'not captured' =="
##############################################################################
# "No hook at all" and "stale hook" have different fixes, and the first is worse:
# nothing has ever uploaded or removed these backups.
run_capture full big missing case3

grep -q 'NOT INSTALLED on this host' <<<"$REPORT" \
  || fail "a missing hook must be reported as not installed:"$'\n'"$REPORT"
grep -q 'nothing has ever uploaded or cleaned up' <<<"$REPORT" \
  || fail "a missing hook must explain why that alone fills the volume"
echo "OK a missing hook is distinguished from a stale one"

##############################################################################
echo "== Proof 4: --analyze must re-read a capture with no aws CLI on PATH =="
##############################################################################
# Collection and analysis are separate so a capture can be reviewed later, by someone
# with no credentials at all.
set +e
REPORT="$(env PATH="/usr/bin:/bin" "$SCRIPT" --analyze "${SANDBOX}/case1" 2>&1)"
RC=$?
set -e
grep -q 'CONFIRMED' <<<"$REPORT" || fail "--analyze did not reproduce the verdict:"$'\n'"$REPORT"
((RC == 0)) || fail "--analyze changed the exit status (got ${RC})"
echo "OK --analyze reproduces the verdict offline"

echo
echo "PASS: offline disk evidence verdict proofs"
