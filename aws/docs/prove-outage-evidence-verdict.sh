#!/bin/bash
# Offline proof for collect-outage-evidence.sh: the section splitter and the verdict
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
# Proofs 4 to 6 are all about not reading evidence into a capture that does not contain
# it: a high-water mark with no failed writes, a capture that cannot show its logs were
# readable, and ENOSPC lines belonging to an entirely different incident.
#
# Usage (from repo root):
#   ./aws/docs/prove-outage-evidence-verdict.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${ROOT}/aws/docs/collect-outage-evidence.sh"

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

# Same reason as the script under test: macOS has shasum, not sha256sum, and these
# proofs are meant to be runnable from a laptop as well as CI.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | awk '{print $1}'
  else
    shasum -a 256 "$@" | awk '{print $1}'
  fi
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
    if [[ "$disk" == full* ]]; then
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
    if [[ "$backups" == "big" ]]; then
      echo "drwx------ 5 root root 4096 Sep  5 05:31 09-05-26"
      # Left behind by a run that finished more than a day ago -- the defect-2 signature.
      echo "DATED_DIR age_s=104400 /home/backup/09-05-26"
    fi
    echo "===SECTION hook_log==="
    if [[ "$backups" == "big" ]]; then
      echo "2026-09-05T05:40:11-04:00 upload system backup /home/backup/09-05-26 -> s3backup:.../server/2026-09-05/"
      echo "2026-09-05T06:02:55-04:00 cleaned local system backup dirs under /home/backup"
    else
      echo "2026-09-06T05:40:11-04:00 OK backup upload and local cleanup complete"
    fi
    echo "===SECTION enospc==="
    # The on-box script lists what it could search before listing what it found, so an
    # empty result can be read as "nothing failed" rather than "nothing to read".
    echo "SEARCHED /var/log/messages"
    echo "SEARCHED /var/log/exim/mainlog"
    if [[ "$disk" == "full" ]]; then
      echo "MATCH Sep  6 05:52:18 server mysqld[1123]: [ERROR] InnoDB: Write to file ./ibtmp1 failed: No space left on device"
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
      current) echo "$(sha256_of "${ROOT}/scripts/directadmin/all_backups_post.sh")  /usr/local/directadmin/scripts/custom/all_backups_post.sh" ;;
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

# Replace the body of the enospc section, reading the new body from stdin. Done with awk
# rather than `sed 's/.../&\n.../'` because BSD sed rejects \n in a replacement and these
# proofs are meant to run from a laptop as well as CI.
rewrite_section() { # section infile outfile <new-body-on-stdin
  local section="$1" infile="$2" outfile="$3" body
  body="$(cat)"
  awk -v body="$body" -v want="===SECTION ${section}===" '
    $0 == want { print; print body; inside = 1; next }
    /^===SECTION / && inside { inside = 0 }
    inside { next }
    { print }
  ' "$infile" >"$outfile"
}

rewrite_enospc() { # infile outfile <new-body-on-stdin
  rewrite_section enospc "$1" "$2"
}

run_prepared() { # remote-out-file casename -> sets OUT_DIR, RC, REPORT
  local remote="$1" case_name="$2"
  OUT_DIR="${SANDBOX}/${case_name}"
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
echo "== Proof 4: a 99% disk that no service failed a write against must REFUTE =="
##############################################################################
# The shape of the real 2026-09-06 capture, and the one this script got wrong: 99% used,
# every log searchable, zero ENOSPC, services healthy. An earlier version called that
# CONSISTENT purely because the number was high, which pointed the investigation at a
# disk that had been sitting at 99% for weeks while the host actually died of memory
# exhaustion. A near-full volume nothing ever failed a write against is not the cause.
run_capture full-quiet small current case4

grep -q 'Full disk explains the outage:      NOT SUPPORTED' <<<"$REPORT" \
  || fail "99% used with zero ENOSPC across searchable logs must NOT be called CONSISTENT:"$'\n'"$REPORT"
grep -q 'searched 2 log file(s)' <<<"$REPORT" \
  || fail "the report must say how many logs were searched, or 'no ENOSPC' is unreadable"
grep -qi 'memory' <<<"$REPORT" \
  || fail "a refutation on this shape must name the next thing to check"
((RC == 1)) || fail "expected exit 1 (contradicted) when the disk is ruled out, got ${RC}"
echo "OK a high-water mark with no failed writes refutes rather than agrees"

##############################################################################
echo "== Proof 5: a capture with no SEARCHED markers must not claim to rule ENOSPC out =="
##############################################################################
# Older captures recorded matches only, so an empty section could equally mean "no logs".
# That is missing evidence, not exculpatory evidence, and must stay INCONCLUSIVE.
LEGACY="${SANDBOX}/case5"
make_remote_out full-quiet small current "${SANDBOX}/case5-remote.txt"
mkdir -p "$LEGACY"
grep -v '^SEARCHED ' "${SANDBOX}/case5-remote.txt" >"${SANDBOX}/case5-legacy.txt"
set +e
REPORT="$(env PATH="${SANDBOX}/bin:${PATH}" \
  STUB_REMOTE_OUT="${SANDBOX}/case5-legacy.txt" STUB_CONSOLE=/dev/null \
  "$SCRIPT" --out "$LEGACY" 2>&1)"
RC=$?
set -e

grep -q 'Full disk explains the outage:      CONSISTENT' <<<"$REPORT" \
  || fail "a capture that cannot show the logs were searchable must stay CONSISTENT, not refute:"$'\n'"$REPORT"
grep -q 'no log covering the incident window' <<<"$REPORT" \
  || fail "the report must say why it cannot rule ENOSPC out"
grep -q 'capture does not record which logs were searchable' <<<"$REPORT" \
  || fail "a legacy capture must be labelled as such rather than given a searched count"
echo "OK absent evidence is not treated as evidence of absence"

##############################################################################
echo "== Proof 6: ENOSPC lines from outside the incident window must not confirm =="
##############################################################################
# 2026-06-28 was a real disk-full failure and logged real ENOSPC lines. Its rotations can
# still be on the box months later, so the on-box capture now selects logs by mtime and
# labels the rest SKIPPED_OLD. Both halves of that have to hold here.
make_remote_out full-quiet small current "${SANDBOX}/case6-remote.txt"

# Case A: in-window logs are clean, and an old rotation is present but was not searched.
# The June lines never reach the capture, so the September verdict must still refute.
rewrite_enospc "${SANDBOX}/case6-remote.txt" "${SANDBOX}/case6a.txt" <<'ENOSPC'
SEARCHED /var/log/messages
SEARCHED /var/log/exim/mainlog
SKIPPED_OLD /var/log/messages-20260628 (last written more than 14d ago)
SKIPPED_OLD /var/log/exim/mainlog-20260628 (last written more than 14d ago)
ENOSPC
run_prepared "${SANDBOX}/case6a.txt" case6a

grep -q 'Full disk explains the outage:      NOT SUPPORTED' <<<"$REPORT" \
  || fail "an old rotation must not change a September refutation:"$'\n'"$REPORT"
grep -q 'skipped 2 written outside the window' <<<"$REPORT" \
  || fail "the report must disclose how many logs were excluded, or the search looks wider than it was"
echo "OK an out-of-window rotation is excluded and disclosed"

# Case B: every log fell outside the window, so there is nothing to search. This is the
# case that fails against the unguarded version: with no SEARCHED lines the analysis took
# the legacy path, counted every line in the section as a match, and turned two
# SKIPPED_OLD *filenames* into "2 ENOSPC lines" -- CONFIRMED from no evidence at all.
rewrite_enospc "${SANDBOX}/case6-remote.txt" "${SANDBOX}/case6b.txt" <<'ENOSPC'
SKIPPED_OLD /var/log/messages-20260628 (last written more than 14d ago)
SKIPPED_OLD /var/log/exim/mainlog-20260628 (last written more than 14d ago)
ENOSPC
run_prepared "${SANDBOX}/case6b.txt" case6b

grep -q 'Full disk explains the outage:      CONSISTENT' <<<"$REPORT" \
  || fail "with every log out of window the disk can be neither confirmed nor ruled out:"$'\n'"$REPORT"
if grep -q 'Full disk explains the outage:      CONFIRMED' <<<"$REPORT"; then
  fail "SKIPPED_OLD filenames were counted as ENOSPC matches -- absence of logs became proof"
fi
grep -q 'all 2 log file(s) were written outside the incident window' <<<"$REPORT" \
  || fail "the report must say the section is unsearchable rather than print a match count of 0"
echo "OK skipped filenames are not mistaken for ENOSPC evidence"

##############################################################################
echo "== Proof 7: ENOSPC records must be dated, not just the file they live in =="
##############################################################################
# Proof 6 bounds which *files* are searched. That is not enough on its own:
# /var/log/exim/paniclog is rarely rotated, so a single panic this week keeps its mtime
# current while it still holds June's disk-full lines. Selecting the file then grepping it
# unbounded hands those June lines to the verdict as September evidence -- the same bias,
# one level down.
#
# The classifier that fixes this lives in the on-box script, which the fixtures above never
# execute. So run the real thing: extract it verbatim between its markers and point it at
# fixture logs. A copy pasted into this proof could drift from production and still pass.

extract_classifier() {
  awk '/# --- BEGIN enospc classifier ---/ {f = 1; next}
       /# --- END enospc classifier ---/   {f = 0}
       f' "$SCRIPT"
}

[[ -n "$(extract_classifier)" ]] \
  || fail "could not extract the enospc classifier -- did its BEGIN/END markers move?"

run_classifier() { # <incident-date> <pad-days> <logfile>... -> sets CLASSIFIED
  local inc="$1" pad="$2"
  shift 2
  run_classifier_split "$inc" "$pad" "$*" ""
}

# Plain and compressed inputs travel separately, because only the compressed ones need a
# decompressor between the file and the grep.
run_classifier_split() { # <incident-date> <pad-days> <plain> <compressed> -> sets CLASSIFIED
  local runner="${SANDBOX}/classifier.sh"
  {
    printf "INCIDENT_DATE='%s'\n" "$1"
    printf "INCIDENT_PAD_DAYS='%s'\n" "$2"
    printf 'enospc_files="%s"\n' "$3"
    printf 'enospc_compressed="%s"\n' "$4"
    extract_classifier
  } >"$runner"
  CLASSIFIED="$(sh "$runner")"
}

if ! date -d '-1 day' '+%Y-%m-%d' >/dev/null 2>&1; then
  fail "GNU 'date -d' is required to date-bound ENOSPC records, and the on-box script needs it too"
fi

LOGS="${SANDBOX}/logs"
mkdir -p "$LOGS"

# Every date here is derived from one incident anchor, so the window and the records move
# together and no literal can drift out of the window. INC is deliberately not today's
# date: the window must be a property of the outage, and a proof that used "now" for both
# sides would pass just as happily against the relative window this replaced.
INC="2026-09-06"
in_syslog="$(date -d "$INC" '+%b %e')"
old_syslog="$(date -d "${INC} -60 days" '+%b %e')"
old_iso="$(date -d "${INC} -60 days" '+%Y-%m-%d')"

{
  echo "${in_syslog} 03:45:02 primary kernel: EXT4-fs (nvme0n1p1): No space left on device"
  echo "${old_syslog} 03:12:44 primary kernel: EXT4-fs (nvme0n1p1): No space left on device"
  echo "${old_iso} 03:12:45 exim paniclog: failed to write: No space left on device"
  echo "spooler: write failed, no space left on device"
} >"${LOGS}/paniclog"

run_classifier "$INC" 1 "${LOGS}/paniclog"

grep -q "^MATCH .*${in_syslog}" <<<"$CLASSIFIED" \
  || fail "a record from inside the window must stay a MATCH:"$'\n'"$CLASSIFIED"
[[ "$(grep -c '^MATCH ' <<<"$CLASSIFIED")" == "1" ]] \
  || fail "exactly one record is in window; the rest must not be counted as evidence:"$'\n'"$CLASSIFIED"
[[ "$(grep -c '^MATCH_OLD ' <<<"$CLASSIFIED")" == "2" ]] \
  || fail "both the syslog and ISO records from 60 days ago must be excluded:"$'\n'"$CLASSIFIED"
[[ "$(grep -c '^MATCH_UNDATED ' <<<"$CLASSIFIED")" == "1" ]] \
  || fail "a record with no parseable timestamp must be reported, not dropped:"$'\n'"$CLASSIFIED"
grep -q "^MATCH_OLD .*${LOGS}/paniclog" <<<"$CLASSIFIED" \
  || fail "excluded records must keep their filename so a human can find them"
echo "OK records are dated individually inside a single current log"

# The verdict side of the same fixture. An out-of-window record must not confirm, and the
# refutation must stay available -- this is the paniclog case reaching analyze().
rewrite_enospc "${SANDBOX}/case6-remote.txt" "${SANDBOX}/case7a.txt" <<ENOSPC
SEARCHED /var/log/exim/paniclog
MATCH_OLD /var/log/exim/paniclog:${old_iso} 03:12:44 No space left on device
ENOSPC
run_prepared "${SANDBOX}/case7a.txt" case7a

if grep -q 'Full disk explains the outage:      CONFIRMED' <<<"$REPORT"; then
  fail "a June ENOSPC record inside a current log confirmed a September outage:"$'\n'"$REPORT"
fi
grep -q 'Full disk explains the outage:      NOT SUPPORTED' <<<"$REPORT" \
  || fail "an out-of-window record must leave the refutation intact:"$'\n'"$REPORT"
grep -q '1 ENOSPC record(s) in those logs dated before the window' <<<"$REPORT" \
  || fail "the excluded record must be disclosed, not silently dropped:"$'\n'"$REPORT"
echo "OK an out-of-window record neither confirms nor disappears"

# An undated record is the case where both verdicts would be dishonest.
rewrite_enospc "${SANDBOX}/case6-remote.txt" "${SANDBOX}/case7b.txt" <<'ENOSPC'
SEARCHED /var/log/exim/paniclog
MATCH_UNDATED /var/log/exim/paniclog:spooler: write failed, no space left on device
ENOSPC
run_prepared "${SANDBOX}/case7b.txt" case7b

grep -q 'Full disk explains the outage:      INCONCLUSIVE' <<<"$REPORT" \
  || fail "an undated ENOSPC record must not be resolved either way:"$'\n'"$REPORT"
if grep -q 'not one service logged ENOSPC' <<<"$REPORT"; then
  fail "the refutation claimed nothing logged ENOSPC while an unread ENOSPC record was in the capture"
fi
grep -q 'timestamp could not be parsed' <<<"$REPORT" \
  || fail "the report must tell the reader to go read the record by hand:"$'\n'"$REPORT"
echo "OK an unreadable timestamp is escalated rather than guessed"

# Capping the raw grep output before dating it throws away evidence in file order. One
# in-window hit in a log grep reads early is displaced by a backlog of historical hits in a
# paniclog it reads later, and what survives is uniformly MATCH_OLD -- so analyze() refutes,
# announcing that nothing logged ENOSPC during the incident, having discarded the line that
# said otherwise. Worse than the unbounded grep it replaced: that one was wrong loudly.
{
  echo "${in_syslog} 03:45:02 primary kernel: EXT4-fs: No space left on device"
} >"${LOGS}/messages"
: >"${LOGS}/paniclog-busy"
i=0
while ((i < 60)); do
  echo "${old_iso} 03:12:${i} exim paniclog: spool write: No space left on device" >>"${LOGS}/paniclog-busy"
  i=$((i + 1))
done

run_classifier "$INC" 1 "${LOGS}/messages" "${LOGS}/paniclog-busy"

grep -q "^MATCH .*${LOGS}/messages" <<<"$CLASSIFIED" \
  || fail "the single in-window record was displaced by 60 older ones:"$'\n'"$CLASSIFIED"
grep -q '^TOTALS in_window=1 out_of_window=60 undated=0' <<<"$CLASSIFIED" \
  || fail "TOTALS must report what was found, not what was printed:"$'\n'"$(grep '^TOTALS' <<<"$CLASSIFIED")"
[[ "$(grep -c '^MATCH_OLD ' <<<"$CLASSIFIED")" -le 10 ]] \
  || fail "out-of-window noise must stay capped or it bloats every capture"
echo "OK evidence is classified before it is capped, and totals survive the cap"

# The verdict side: a capture whose printed lines were capped must still confirm, because
# TOTALS says an in-window record exists even though its line did not fit.
rewrite_enospc "${SANDBOX}/case6-remote.txt" "${SANDBOX}/case7c.txt" <<ENOSPC
SEARCHED /var/log/messages
SEARCHED /var/log/exim/paniclog
MATCH_OLD /var/log/exim/paniclog:${old_iso} 03:12:01 No space left on device
TOTALS in_window=3 out_of_window=97 undated=0
ENOSPC
run_prepared "${SANDBOX}/case7c.txt" case7c

grep -q 'Full disk explains the outage:      CONFIRMED' <<<"$REPORT" \
  || fail "the verdict ignored TOTALS and refuted on the capped lines:"$'\n'"$REPORT"
grep -q 'host logs: 3 ' <<<"$REPORT" \
  || fail "the report must show the true in-window count, not the printed one:"$'\n'"$REPORT"
echo "OK a capped capture is read by its totals, not its surviving lines"

# logrotate compresses by default, so the newest rotation of a busy log is usually .gz --
# and a recent rotation is exactly where an incident's last lines end up before the current
# file rolls over. Handing that to a plain grep searches the compressed bytes, finds
# nothing whatever the file says, and still counts the file as SEARCHED, so the verdict is
# told the log was examined and came up clean.
{
  echo "${in_syslog} 03:45:07 primary kernel: EXT4-fs: No space left on device"
  echo "${in_syslog} 03:45:08 primary kernel: unrelated line"
} >"${LOGS}/messages-rotated"
gzip -f "${LOGS}/messages-rotated"

run_classifier_split "$INC" 1 "" "${LOGS}/messages-rotated.gz"

grep -q '^MATCH .*messages-rotated\.gz:' <<<"$CLASSIFIED" \
  || fail "an ENOSPC record inside a gzipped rotation was not found:"$'\n'"$CLASSIFIED"
grep -q '^TOTALS in_window=1 out_of_window=0 undated=0' <<<"$CLASSIFIED" \
  || fail "the compressed match must be counted like any other:"$'\n'"$CLASSIFIED"
echo "OK a gzipped rotation is decompressed rather than grepped as bytes"

# A log inside the window that nothing on the host could open is not evidence of absence.
rewrite_enospc "${SANDBOX}/case6-remote.txt" "${SANDBOX}/case7d.txt" <<'ENOSPC'
SEARCHED /var/log/messages
SKIPPED_UNREADABLE /var/log/messages-20260901.zst (needs zstd, which is not installed)
ENOSPC
run_prepared "${SANDBOX}/case7d.txt" case7d

grep -q 'Full disk explains the outage:      INCONCLUSIVE' <<<"$REPORT" \
  || fail "an unreadable in-window log must block a refutation:"$'\n'"$REPORT"
grep -q 'could not be read' <<<"$REPORT" \
  || fail "the report must say which logs could not be opened:"$'\n'"$REPORT"
echo "OK a log that could not be opened is not counted as searched"

# The window used to be "the 14 days before collection", which makes the verdict depend on
# when somebody got round to running this. Two ways that goes wrong, and this covers both
# with one fixture: a disk-full event weeks before the outage is inside a 14-day window if
# you collect promptly, and an event *after* the outage is inside it too. Neither is
# evidence about the incident. The anchor is now the incident date, so a record written
# today is out of window when the outage was months ago -- which is the assertion the old
# behaviour cannot satisfy.
#
# Anchored on 2026-06-28, the earlier genuine disk-full failure on this same host, because
# investigating it today is the concrete case: a record written today is months away from
# that outage and must not count, yet a window measured backwards from collection puts it
# at the very centre.
OLD_INC="2026-06-28"
{
  echo "$(date '+%b %e') 04:02:11 primary kernel: EXT4-fs: No space left on device"
  echo "$(date -d "${OLD_INC} +30 days" '+%Y-%m-%d') 04:02:12 exim paniclog: No space left on device"
  echo "$(date -d "$OLD_INC" '+%Y-%m-%d') 03:45:02 primary kernel: EXT4-fs: No space left on device"
} >"${LOGS}/messages-anchored"

# Guard against this proof quietly losing its point if it is ever run on 2026-06-27..29.
if [[ "$(date '+%b %e')" == "$(date -d "$OLD_INC" '+%b %e')" ]]; then
  fail "this proof needs today to be outside the anchored window; pick a different OLD_INC"
fi

run_classifier "$OLD_INC" 1 "${LOGS}/messages-anchored"

grep -q '^TOTALS in_window=1 out_of_window=2 undated=0' <<<"$CLASSIFIED" \
  || fail "only the record from the incident window may count:"$'\n'"$CLASSIFIED"
grep -q "^MATCH .*$(date -d "$OLD_INC" '+%Y-%m-%d')" <<<"$CLASSIFIED" \
  || fail "the incident's own record must be the one that matches:"$'\n'"$CLASSIFIED"
grep -q "^MATCH_OLD .*$(date '+%b %e')" <<<"$CLASSIFIED" \
  || fail "a record written today is not evidence about an outage in June:"$'\n'"$CLASSIFIED"
echo "OK the window follows the incident, not the day the capture was taken"

##############################################################################
echo "== Proof 8: a capture that was cut off must not produce a confident answer =="
##############################################################################
# SSM caps StandardOutputContent at 24000 characters and the sections are written in
# order, so what gets dropped is the tail: enospc, journal_errors, services. What survives
# is the head: disk usage and backup sizes. That is the worst possible subset -- everything
# that looks like support for the disk hypothesis arrives, everything that could refute it
# does not, and the old code paired CONSISTENT with CONFIRMED and exited 0 on the strength
# of it. A warning on stderr at collection time does not reach whoever runs --analyze on
# the saved directory a day later.
TRUNC="${SANDBOX}/case8-trunc"
rm -rf "$TRUNC"
cp -r "${SANDBOX}/case1" "$TRUNC"
rm -f "${TRUNC}/section-enospc.txt"
printf 'no ===SECTION END=== marker; SSM caps StandardOutputContent at 24000 chars\n' \
  >"${TRUNC}/capture-truncated"

set +e
REPORT="$("$SCRIPT" --analyze "$TRUNC" 2>&1)"
RC=$?
set -e

grep -q 'Full disk explains the outage:      INCONCLUSIVE' <<<"$REPORT" \
  || fail "a truncated capture must not rule on the disk:"$'\n'"$REPORT"
((RC == 2)) \
  || fail "a truncated capture must exit 2 (inconclusive), got ${RC}:"$'\n'"$REPORT"
grep -q 'no END marker' <<<"$REPORT" \
  || fail "the reader must be told why the verdict was withheld:"$'\n'"$REPORT"
echo "OK a cut-off capture is refused rather than read optimistically"

# The other half: truncation removes the ability to prove absence, not the value of
# evidence that did arrive. Case 1 has real ENOSPC lines, so its confirmation must survive.
TRUNC2="${SANDBOX}/case8-trunc-confirmed"
rm -rf "$TRUNC2"
cp -r "${SANDBOX}/case1" "$TRUNC2"
printf 'no ===SECTION END=== marker\n' >"${TRUNC2}/capture-truncated"

set +e
REPORT="$("$SCRIPT" --analyze "$TRUNC2" 2>&1)"
RC=$?
set -e

grep -q 'Full disk explains the outage:      CONFIRMED' <<<"$REPORT" \
  || fail "an ENOSPC line that did arrive is still evidence; truncation must not erase it:"$'\n'"$REPORT"
((RC == 0)) || fail "a surviving confirmation keeps its exit status, got ${RC}"
echo "OK truncation withholds absence, not presence"

##############################################################################
echo "== Proof 9: a backup mid-upload must not be read as a cleanup failure =="
##############################################################################
# The cause verdict was a size test and nothing else, so any capture with a large local
# footprint concluded that the hook's cleanup had failed. But cleanup runs *after* the
# upload verifies, so during a backup -- or during the rclone run that follows it -- tens
# of gigabytes on disk is the system behaving exactly as designed. The collector has
# recorded pgrep for rclone since the beginning and nothing ever read it.
#
# This matters most in the situation someone would actually run this: the disk is filling,
# so they capture immediately, which is when a backup is most likely to be in flight.
BIG_RUNNING="${SANDBOX}/case9-running"
rm -rf "$BIG_RUNNING"
cp -r "${SANDBOX}/case1" "$BIG_RUNNING"
printf 'rclone copy /home/admin_backups s3backup:bucket/host/2026-09-06/ --checksum\n' \
  >"${BIG_RUNNING}/section-rclone_running.txt"
# No completed run that went wrong: no ERROR lines in the hook log, and no dated
# directories left behind from a previous cleanup that freed nothing.
: >"${BIG_RUNNING}/section-hook_log.txt"
: >"${BIG_RUNNING}/section-backup_listing.txt"

set +e
REPORT="$("$SCRIPT" --analyze "$BIG_RUNNING" 2>&1)"
set -e

if grep -q 'Backup cleanup is why it filled:    CONFIRMED' <<<"$REPORT"; then
  fail "a live upload was reported as a cleanup failure:"$'\n'"$REPORT"
fi
grep -q 'Backup cleanup is why it filled:    INCONCLUSIVE' <<<"$REPORT" \
  || fail "a mid-upload capture must withhold the cause verdict:"$'\n'"$REPORT"
grep -q 'rclone is running in this capture' <<<"$REPORT" \
  || fail "the report must say why the cause was withheld:"$'\n'"$REPORT"
echo "OK an upload in flight explains the footprint instead of indicting the hook"

# The guard must not become an excuse. A run that already finished badly leaves stale dated
# directories behind, and that is evidence regardless of what is running now.
BIG_STALE="${SANDBOX}/case9-stale"
rm -rf "$BIG_STALE"
cp -r "${SANDBOX}/case1" "$BIG_STALE"
printf 'rclone copy /home/admin_backups s3backup:bucket/host/2026-09-06/ --checksum\n' \
  >"${BIG_STALE}/section-rclone_running.txt"

set +e
REPORT="$("$SCRIPT" --analyze "$BIG_STALE" 2>&1)"
set -e

grep -q 'Backup cleanup is why it filled:    CONFIRMED' <<<"$REPORT" \
  || fail "stale directories are evidence of a failed run whatever rclone is doing now:"$'\n'"$REPORT"
echo "OK a concurrent upload does not excuse a run that already failed"

# And the thing that made the guard above almost useless: staleness was inferred from the
# directory's *name*. Every healthy system backup has today's dated directory on disk while
# it is being written, so the guard's own precondition -- no stale directories -- was false
# in precisely the situation it was written for. Age, not name.
ACTIVE_DIR="${SANDBOX}/case9-active"
rm -rf "$ACTIVE_DIR"
cp -r "${SANDBOX}/case1" "$ACTIVE_DIR"
printf 'rclone copy /backup/09-06-26 s3backup:bucket/host/2026-09-06/ --checksum\n' \
  >"${ACTIVE_DIR}/section-rclone_running.txt"
: >"${ACTIVE_DIR}/section-hook_log.txt"
{
  echo "--- /backup ---"
  echo "drwx------ 5 root root 4096 Sep  6 03:50 09-06-26"
  # Written to four minutes ago: this is the backup in flight, not a leftover.
  echo "DATED_DIR age_s=240 /backup/09-06-26"
} >"${ACTIVE_DIR}/section-backup_listing.txt"

set +e
REPORT="$("$SCRIPT" --analyze "$ACTIVE_DIR" 2>&1)"
set -e

grep -q 'still being written: 1' <<<"$REPORT" \
  || fail "an actively written directory must be reported as such:"$'\n'"$REPORT"
grep -q 'left behind (idle > 6h): 0' <<<"$REPORT" \
  || fail "a directory touched four minutes ago is not a leftover:"$'\n'"$REPORT"
if grep -q 'Backup cleanup is why it filled:    CONFIRMED' <<<"$REPORT"; then
  fail "today's in-progress directory was counted as evidence of a failed cleanup:"$'\n'"$REPORT"
fi
echo "OK the directory being written right now does not count as a leftover"

##############################################################################
echo "== Proof 10: 'we could not check' must not exit like 'the hypothesis holds' =="
##############################################################################
# CONSISTENT is what this script says when it had no log covering the window to search --
# its own note spells out that ENOSPC can be neither confirmed nor ruled out. Pairing that
# with a confirmed cause used to exit 0, so any caller reading the status instead of the
# report was told the disk theory was established. A nearly-full volume with a large local
# backup footprint is a state a healthy host reaches routinely, which makes this the
# easiest false confirmation in the script to trigger.
#
# Round 6 stopped truncated captures from doing this. A complete capture whose logs had
# simply rotated away still could.
ROTATED="${SANDBOX}/case10-rotated"
rm -rf "$ROTATED"
cp -r "${SANDBOX}/case1" "$ROTATED"
# Complete capture, high usage, big backups, a genuinely failed run -- and not one log
# left inside the window to search.
: >"${ROTATED}/section-enospc.txt"

set +e
REPORT="$("$SCRIPT" --analyze "$ROTATED" 2>&1)"
RC=$?
set -e

grep -q 'Full disk explains the outage:      CONSISTENT' <<<"$REPORT" \
  || fail "fixture did not hold: expected the no-searchable-logs verdict:"$'\n'"$REPORT"
grep -q 'Backup cleanup is why it filled:    CONFIRMED' <<<"$REPORT" \
  || fail "fixture did not hold: expected the cause to be confirmed:"$'\n'"$REPORT"
((RC == 2)) \
  || fail "a disk verdict that was never established must exit inconclusive, got ${RC}:"$'\n'"$REPORT"
echo "OK an unverifiable disk verdict exits 2 however strong the cause looks"

# And the decisive status must still be reachable, or the change is just a downgrade.
set +e
"$SCRIPT" --analyze "${SANDBOX}/case1" >/dev/null 2>&1
RC=$?
set -e
((RC == 0)) \
  || fail "a logged ENOSPC plus a confirmed cause must still exit 0, got ${RC}"
echo "OK a service that actually logged ENOSPC still earns a decisive 0"

##############################################################################
echo "== Proof 11: --analyze must re-read a capture with no aws CLI on PATH =="
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
