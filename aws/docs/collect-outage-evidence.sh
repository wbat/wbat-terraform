#!/bin/bash
# Confirm (or refute) the 2026-09-06 root-disk hypothesis with evidence from the box.
#
# This answers two questions from the box rather than from the repository:
#
#   1. Did the disk actually fill, and did that break the services?
#   2. Was it the backups -- and if so, which defect fired?
#
# On 2026-09-06 it answered "no" to both, which is the whole reason it exists: the
# repository-only analysis had concluded the opposite. See
# aws/docs/2026-09-06-primary-outage.md for what the evidence actually showed.
#
# It collects over SSM, saves the output as a fixture, and prints a verdict.
# Deliberately read-only: it changes nothing, so it is safe to run before recovering the
# space (and running it after a cleanup will say so rather than mislead).
#
# Usage:
#   ./collect-outage-evidence.sh                        # primary, collect + analyse
#   ./collect-outage-evidence.sh --host secondary
#   ./collect-outage-evidence.sh --profile wbat --out /tmp/capture
#   ./collect-outage-evidence.sh --analyze DIR          # offline; no AWS needed
#
# Needs ssm:SendCommand + ssm:GetCommandInvocation and the SSM agent running on the
# instance. --analyze re-reads a previous capture and needs no credentials at all, which
# is also how the verdict logic is testable without a box.
#
# Exit status: 0 = hypothesis confirmed, 1 = contradicted (look elsewhere),
#              2 = inconclusive, 3 = collection failed.
# 0 requires a service to have logged ENOSPC inside the window. Disk usage and backup
# sizes on their own are 2: they describe a state a healthy host reaches routinely.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOST_ROLE="primary"
PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-us-east-1}"
OUT_DIR=""
ANALYZE_DIR=""

# Thresholds for the verdict. A volume this full is the story regardless of what else is
# on it, and backups this large are the story regardless of how full the volume is now.
FULL_PCT=90
BACKUP_GB_SIGNIFICANT=20
BACKUP_SHARE_PCT=25

# The incident this script is about, and how far either side of it a record still counts.
# These are dates, not offsets from today: an ENOSPC line is evidence for this outage
# because of when it was written, not because of when somebody got round to collecting it.
# Anchoring on "the last 14 days" meant a capture taken on the 7th accepted an unrelated
# disk-full event from late August, and a capture taken weeks later would accept events
# that postdate the outage entirely -- either way the collector confirms the hypothesis
# from a record that has nothing to do with it.
INCIDENT_DATE="${INCIDENT_DATE:-2026-09-06}"
INCIDENT_PAD_DAYS="${INCIDENT_PAD_DAYS:-1}"

# How long a dated backup directory can go untouched before it is a leftover rather than
# one being written. The Aug 29 system backup ran 22 minutes; six hours is well clear of a
# slow run while still catching anything the previous night left behind.
ACTIVE_DIR_MAX_AGE_S=21600

if [[ ! "$INCIDENT_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: INCIDENT_DATE must be YYYY-MM-DD, got '${INCIDENT_DATE}'" >&2
  exit 3
fi
if [[ ! "$INCIDENT_PAD_DAYS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: INCIDENT_PAD_DAYS must be a whole number of days, got '${INCIDENT_PAD_DAYS}'" >&2
  exit 3
fi

usage() { sed -n '2,26p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST_ROLE="${2:-}"
      shift 2
      ;;
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --region)
      REGION="${2:-}"
      shift 2
      ;;
    --out)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --analyze)
      ANALYZE_DIR="${2:-}"
      shift 2
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

case "$HOST_ROLE" in
  primary) NAME_TAG="WBAT Primary Server" ;;
  secondary) NAME_TAG="WBAT Secondary Server" ;;
  *)
    echo "ERROR: --host must be primary or secondary" >&2
    exit 2
    ;;
esac

aws_() {
  local args=(--region "$REGION")
  [[ -n "$PROFILE" ]] && args+=(--profile "$PROFILE")
  command aws "${args[@]}" "$@"
}

section_file() { echo "${1}/section-${2}.txt"; }

# macOS ships `shasum`, not `sha256sum`, and this repo's scripts are run from laptops
# (cost-optimization-checklist.md uses BSD `date -u -v` syntax). This matters more than
# portability tidiness: the hook-version comparison below feeds an empty hash into a
# string equality test if the tool is missing, which reports a perfectly current hook as
# "hand-edited on the box" -- a confidently wrong answer instead of an absent one.
# Reads a file argument, or stdin when called with none.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@" | awk '{print $1}'
  else
    return 1
  fi
}

have_sha256() {
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1
}

##############################################################################
# Collection
##############################################################################

# Kept compact on purpose: GetCommandInvocation truncates StandardOutputContent at 24000
# characters, and routing around that needs an S3 output bucket. Every command below is
# bounded (tail/head/max-depth) so the whole capture fits.
remote_script() {
  # The only values interpolated into the remote script. Both are validated at startup, so
  # this cannot inject anything, and single quotes keep the remote shell from re-reading
  # them. Everything else is a quoted heredoc.
  printf "INCIDENT_DATE='%s'\nINCIDENT_PAD_DAYS='%s'\n" "$INCIDENT_DATE" "$INCIDENT_PAD_DAYS"
  cat <<'REMOTE'
echo "===SECTION host==="
date -u +%Y-%m-%dT%H:%M:%SZ
hostname -f 2>/dev/null || hostname
uptime
echo "===SECTION df==="
df -Pk /
df -Pi /
echo "===SECTION df_h==="
df -h / /home 2>/dev/null
echo "===SECTION backup_usage==="
# /backup as well as /home/backup: the primary writes system backups to the former, and
# looking only at the latter reported "0.0 GB of backups" while 59 GB sat one path over.
du -sk /home/admin_backups /home/backup /backup 2>/dev/null
echo "===SECTION top_dirs==="
du -xk --max-depth=2 / 2>/dev/null | sort -rn | head -25
echo "===SECTION backup_listing==="
for d in /home/backup /backup /home/admin_backups; do
  echo "--- $d ---"
  ls -la "$d/" 2>/dev/null
done
# The name says which day a backup is for; it does not say whether anything is still
# writing to it. Today's directory is present during every healthy system backup, so
# counting dated names as "stale" reports the normal case as a failure -- and defeats the
# in-flight-upload guard in analyze(), which is exactly the situation it was added for.
# Emit the age so staleness can be a fact about the directory rather than about its name.
enospc_now="$(date +%s)"
for d in /home/backup /backup; do
  [ -d "$d" ] || continue
  find "$d" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9]-[0-9][0-9]-[0-9][0-9]' \
    -printf '%T@ %p\n' 2>/dev/null \
    | while read -r ts p; do
      echo "DATED_DIR age_s=$((enospc_now - ${ts%.*})) ${p}"
    done
done
echo "===SECTION hook_log==="
tail -150 /var/log/da-backup-s3.log 2>/dev/null
echo "===SECTION log_sizes==="
ls -la /var/log/da-backup-s3.log* /var/log/da-vhost-listen.log* 2>/dev/null
echo "===SECTION installed_hashes==="
for f in /usr/local/directadmin/scripts/custom/all_backups_post.sh \
         /usr/local/directadmin/scripts/custom/system_backup_post.sh \
         /usr/local/sbin/da-disk-guard.sh; do
  if [ -f "$f" ]; then sha256sum "$f"; else echo "MISSING $f"; fi
done
echo "===SECTION backup_schedule==="
head -40 /usr/local/directadmin/data/admin/backup_crons.list 2>/dev/null
echo "===SECTION enospc==="
# Record which files were actually searchable. Without this, "no ENOSPC anywhere" and
# "no logs to grep" produce an identical empty section, and they mean opposite things:
# the first is evidence the disk did not break anything, the second is no evidence at all.
#
# Bound the search to the incident window as well. 2026-06-28 was a genuine disk-full
# failure that logged real ENOSPC lines, so if one of its rotations is still on the box an
# unbounded grep hands those lines to the verdict -- which treats any match as proof and
# would confirm the wrong cause for a later outage. A rotation's mtime is when it stopped
# being written, so selecting on mtime needs no timestamp parsing and does not care that
# syslog omits the year. One list feeds both the markers and the grep; they were separate
# before and could drift out of sync.
# A log that stopped being written before the window opened cannot contain a record from
# inside it, whatever today's date is. Selecting on "modified since the window opened"
# rather than "modified in the last 14 days" means a capture taken late still searches the
# right rotations, and a capture taken promptly does not drag in months of unrelated ones.
ENOSPC_FILE_SINCE="$(date -d "${INCIDENT_DATE} -${INCIDENT_PAD_DAYS} days" +%Y-%m-%d)"

# logrotate compresses rotations by default, so the newest rotation of a busy log is very
# often messages-20260901.gz. Passing that to a plain grep searches the compressed bytes,
# which finds nothing no matter what the file says -- while the file still counted as
# SEARCHED, so the verdict was told the log had been examined and had come up clean. A
# recent rotation is precisely where an incident's last words end up before the current
# file rolls over, so this is the case most likely to matter.
# Which decompressor a file needs, and whether this host has it. A missing tool must make
# the file unsearchable rather than silently empty: "we looked and found nothing" and "we
# could not look" are the two states this whole section exists to keep apart.
enospc_tool_for() {
  case "$1" in
    *.gz) printf 'gzip' ;;
    *.bz2) printf 'bzip2' ;;
    *.xz) printf 'xz' ;;
    *.zst) printf 'zstd' ;;
    *) printf 'cat' ;;
  esac
}

enospc_files=""
enospc_compressed=""
for f in /var/log/messages /var/log/messages-* /var/log/mysqld.log \
         /var/log/mariadb/mariadb.log /var/log/exim/mainlog /var/log/exim/mainlog-* \
         /var/log/exim/paniclog /var/log/maillog /var/log/maillog-*; do
  [ -f "$f" ] || continue
  if [ -z "$(find "$f" -maxdepth 0 -newermt "$ENOSPC_FILE_SINCE" 2>/dev/null)" ]; then
    echo "SKIPPED_OLD $f (last written before ${ENOSPC_FILE_SINCE}, so it predates the incident window)"
    continue
  fi
  tool="$(enospc_tool_for "$f")"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIPPED_UNREADABLE $f (needs ${tool}, which is not installed)"
    continue
  fi
  echo "SEARCHED $f"
  if [ "$tool" = "cat" ]; then
    enospc_files="${enospc_files} ${f}"
  else
    enospc_compressed="${enospc_compressed} ${f}"
  fi
done
# mtime bounds the file, not the records inside it. /var/log/exim/paniclog is the case that
# breaks that assumption: it is rarely rotated, so one panic this week leaves it "recent"
# while still holding June's disk-full lines. Those would be handed to the verdict as proof
# for September. So date each hit as well.
#
# Comparing against pre-rendered date strings avoids parsing arbitrary log formats and
# sidesteps syslog omitting the year -- a "Sep  6" line is in window because the string for
# a day in the window is literally "Sep  6". Covers syslog (Sep  6), ISO (2026-09-06) and
# the old MySQL stamp (260906).
# --- BEGIN enospc classifier ---
# prove-outage-evidence-verdict.sh extracts everything between these two markers and runs
# it verbatim against fixture logs, so this block is the tested artefact rather than a
# paraphrase of it. It depends only on INCIDENT_DATE, INCIDENT_PAD_DAYS, enospc_files and
# enospc_compressed, all set above.
enospc_reader() {
  case "$1" in
    *.gz) gzip -dc -- "$1" ;;
    *.bz2) bzip2 -dc -- "$1" ;;
    *.xz) xz -dc -- "$1" ;;
    *.zst) zstd -dc -- "$1" ;;
    *) cat -- "$1" ;;
  esac
}

# Walk forward from the start of the incident window rather than back from today, so the
# set of accepted dates is a property of the outage and not of when this was run twice.
window_start="$(date -d "${INCIDENT_DATE} -${INCIDENT_PAD_DAYS} days" +%Y-%m-%d)"
window_span=$((INCIDENT_PAD_DAYS * 2 + 1))
window_re=""
n=0
while [ "$n" -lt "$window_span" ]; do
  for fmt in '+%Y-%m-%d' '+%b %e' '+%b %d' '+%y%m%d'; do
    t="$(date -d "${window_start} +${n} days" "$fmt" 2>/dev/null)" || t=""
    [ -n "$t" ] && window_re="${window_re}|${t}"
  done
  n=$((n + 1))
done
window_re="$(printf '%s' "$window_re" | sed 's/^|//')"

# Anything that starts with a timestamp we recognise but is not in the window is dated and
# excluded. Anything we cannot date at all is reported separately rather than silently
# counted either way: analyze() must not confirm from it, and must not claim the disk is
# cleared while it exists.
DATED_RE='^([A-Z][a-z][a-z] [ 0-9][0-9] |[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]|[0-9][0-9][0-9][0-9][0-9][0-9] )'

# -H keeps the filename on every hit. The old -h stripped it, so a capture gave no way to
# tell which log, or which rotation, a match came from.
#
# Classify before capping, never after. A cap applied to the raw grep output is applied in
# file order, so a single in-window hit in /var/log/messages can be pushed out by a hundred
# historical hits in a paniclog that grep reaches later. The capture then holds nothing but
# MATCH_OLD, and analyze() refutes -- stating that no service logged ENOSPC during the
# incident, on the strength of having thrown away the line that said one did. Caps are per
# class so out-of-window noise cannot crowd out evidence, and TOTALS reports the true
# counts so the verdict never depends on how many lines were printed.
#
# One awk pass rather than two greps per line: this runs on a host that is already sick.
ENOSPC_PAT="no space left|ENOSPC|disk full|out of disk"
if [ -n "$enospc_files" ] || [ -n "$enospc_compressed" ]; then
  {
    [ -n "$enospc_files" ] && grep -iHE "$ENOSPC_PAT" $enospc_files 2>/dev/null
    # Decompressed streams have no filename of their own, so it is prefixed back on in the
    # same file:line shape grep -H produces, which is what the classifier splits on.
    for cf in $enospc_compressed; do
      enospc_reader "$cf" 2>/dev/null | grep -iE "$ENOSPC_PAT" 2>/dev/null \
        | sed "s|^|${cf}:|"
    done
    true
  } \
    | awk -v win="$window_re" -v dated="$DATED_RE" '
        { rec = $0; sub(/^[^:]*:/, "", rec) }
        rec ~ "^(" win ")"  { n_in++;  if (n_in  <= 40) print "MATCH " $0;         next }
        rec ~ dated         { n_out++; if (n_out <= 10) print "MATCH_OLD " $0;     next }
                            { n_un++;  if (n_un  <= 10) print "MATCH_UNDATED " $0 }
        END { printf "TOTALS in_window=%d out_of_window=%d undated=%d\n", n_in, n_out, n_un }
      '
fi
# --- END enospc classifier ---
echo "===SECTION journal_errors==="
journalctl --since "-4 days" -p err --no-pager 2>/dev/null | tail -60
echo "===SECTION services==="
for s in mysqld mariadb exim nginx httpd directadmin; do
  printf '%s=%s\n' "$s" "$(systemctl is-active $s 2>/dev/null || echo unknown)"
done
echo "===SECTION rclone_running==="
pgrep -a rclone 2>/dev/null || echo "(none)"
echo "===SECTION END==="
REMOTE
}

collect() {
  local out="$1"
  mkdir -p "$out"

  if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: aws CLI not found. Install it, or run --analyze on an existing capture." >&2
    return 3
  fi

  echo "Resolving ${HOST_ROLE} instance by tag Name=\"${NAME_TAG}\"..." >&2
  local instance_id
  instance_id="$(aws_ ec2 describe-instances \
    --filters "Name=tag:Name,Values=${NAME_TAG}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)"
  if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
    echo "ERROR: no running instance tagged \"${NAME_TAG}\" in ${REGION}." >&2
    echo "       The cost doc's warning applies: never hardcode an instance ID here." >&2
    return 3
  fi
  echo "$instance_id" >"${out}/instance-id.txt"
  date -u +%Y-%m-%dT%H:%M:%SZ >"${out}/captured_at_utc.txt"
  echo "Instance: ${instance_id}" >&2

  # AWS-side context first: it answers "was it down, and when" independently of the box,
  # and still works if the SSM agent is wedged.
  aws_ ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].{State:State.Name,Launch:LaunchTime,Type:InstanceType,Reason:StateTransitionReason}' \
    --output json >"$(section_file "$out" instance_state)" 2>&1 || true

  # Kernel messages survive a wedged userland, so ENOSPC often shows here even when the
  # box was too full for its own logging to work.
  aws_ ec2 get-console-output --instance-id "$instance_id" --latest --output text \
    >"$(section_file "$out" console_output)" 2>&1 || true

  aws_ cloudwatch get-metric-statistics --namespace AWS/EC2 \
    --metric-name StatusCheckFailed --dimensions "Name=InstanceId,Value=${instance_id}" \
    --start-time "$(date -u -d '4 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-4d +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 3600 --statistics Maximum --output json \
    >"$(section_file "$out" status_checks)" 2>&1 || true

  echo "Running read-only diagnostics over SSM..." >&2
  local params_json
  params_json="$(remote_script | python3 -c '
import json,sys
print(json.dumps({"commands": sys.stdin.read().split("\n")}))
')" || return 3

  local command_id
  command_id="$(aws_ ssm send-command --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript --comment "disk-full evidence capture" \
    --parameters "$params_json" --query 'Command.CommandId' --output text 2>&1)"
  if [[ -z "$command_id" || "$command_id" == *"error"* || "$command_id" == *"Error"* ]]; then
    echo "ERROR: ssm send-command failed: ${command_id}" >&2
    echo "       Check ssm:SendCommand permission and that the SSM agent is running." >&2
    return 3
  fi
  echo "$command_id" >"${out}/ssm-command-id.txt"

  # `wait` exits non-zero when the command itself failed; the output is still worth
  # fetching, since a partial capture usually names its own problem.
  aws_ ssm wait command-executed --command-id "$command_id" --instance-id "$instance_id" 2>/dev/null

  local raw="${out}/ssm-raw-output.txt"
  aws_ ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
    --query 'StandardOutputContent' --output text >"$raw" 2>&1
  aws_ ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
    --query 'StandardErrorContent' --output text >"${out}/ssm-stderr.txt" 2>&1 || true

  if ! grep -q '===SECTION host===' "$raw"; then
    echo "ERROR: SSM returned no usable output. First lines:" >&2
    head -10 "$raw" >&2
    return 3
  fi

  # Split the marker stream into one file per section so the capture reads like the
  # nginx-catchall fixture rather than one wall of text.
  awk -v out="$out" '
    /^===SECTION [A-Za-z_]+===$/ {
      name = $2
      sub(/===$/, "", name)   # $2 is "host===", not "host"
      file = (name == "END") ? "" : out "/section-" name ".txt"
      next
    }
    file != "" { print > file }
  ' "$raw"

  if grep -q '===SECTION END===' "$raw"; then
    rm -f "${out}/capture-truncated"
    echo "Capture complete: ${out}" >&2
  else
    # A warning on stderr is not enough, and it is not enough in a specific direction.
    # The sections are emitted in order and enospc is near the end, so the output limit
    # removes the evidence that would refute the disk hypothesis while leaving the disk
    # usage and backup sizes that appear to support it. analyze() would then combine
    # CONSISTENT with CONFIRMED and exit 0 -- its most decisive answer, produced from a
    # capture whose relevant half never arrived. Record it in the capture so --analyze
    # sees it later too, when the stderr warning is long gone.
    printf 'no ===SECTION END=== marker; SSM caps StandardOutputContent at 24000 chars\n' \
      >"${out}/capture-truncated"
    echo "WARN capture looks truncated (no END marker); SSM caps output at 24000 chars." >&2
  fi
  return 0
}

##############################################################################
# Analysis
##############################################################################

read_section() {
  local dir="$1" name="$2"
  local f
  f="$(section_file "$dir" "$name")"
  [[ -f "$f" ]] && cat "$f"
}

# Which committed version of the hook is installed? This repo has no deploy pipeline, so
# "the fix is merged" and "the fix is running" are different facts, and a stale hook is
# itself one of the documented causes of a full disk.
identify_installed_hook() {
  local installed_hash="$1"
  local path="scripts/directadmin/all_backups_post.sh"

  if ! have_sha256; then
    echo "unidentified (no sha256sum or shasum available here to compare against the repo)"
    return 0
  fi

  local wt_hash
  wt_hash="$(sha256_of "${REPO_DIR}/${path}" 2>/dev/null)"
  if [[ -n "$wt_hash" && "$installed_hash" == "$wt_hash" ]]; then
    echo "current (matches this checkout)"
    return 0
  fi

  local commit
  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    local h
    h="$(git -C "$REPO_DIR" show "${commit}:${path}" 2>/dev/null | sha256_of)"
    if [[ "$h" == "$installed_hash" ]]; then
      echo "the version from commit $(git -C "$REPO_DIR" log -1 --format='%h %s' "$commit" 2>/dev/null)"
      return 0
    fi
  done < <(git -C "$REPO_DIR" log --all --format='%H' -- "$path" 2>/dev/null)

  echo "no committed version (hand-edited on the box)"
}

analyze() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    echo "ERROR: no such capture directory: $dir" >&2
    return 3
  fi

  local captured host_name
  captured="$(cat "${dir}/captured_at_utc.txt" 2>/dev/null || echo unknown)"
  host_name="$(read_section "$dir" host | sed -n '2p')"

  echo "================================================================"
  echo "Evidence review: ${host_name:-unknown host} (captured ${captured})"
  echo "================================================================"

  # --- disk state ---
  local used_pct=-1 avail_gb="?" inode_pct=-1 used_kb=0
  if [[ -f "$(section_file "$dir" df)" ]]; then
    read -r used_pct avail_gb used_kb < <(
      read_section "$dir" df | awk '/^\/|[0-9]+%/ && NF>=6 && $5 ~ /%/ {gsub(/%/,"",$5); printf "%d %.1f %d\n", $5, $4/1048576, $3; exit}'
    )
    inode_pct="$(read_section "$dir" df | awk 'NR>1 && $5 ~ /%/ {gsub(/%/,"",$5); print $5+0}' | tail -1)"
  fi
  used_pct="${used_pct:--1}"
  inode_pct="${inode_pct:--1}"
  used_kb="${used_kb:-0}"

  # --- backup footprint ---
  local backup_kb=0 backup_gb=0 share=0
  if [[ -f "$(section_file "$dir" backup_usage)" ]]; then
    backup_kb="$(read_section "$dir" backup_usage | awk '{s+=$1} END {print s+0}')"
  fi
  backup_gb="$(awk -v k="$backup_kb" 'BEGIN {printf "%.1f", k/1048576}')"
  if ((used_kb > 0)); then
    share="$(awk -v b="$backup_kb" -v u="$used_kb" 'BEGIN {printf "%d", (b*100)/u}')"
  fi

  echo
  echo "-- Disk --"
  if ((used_pct >= 0)); then
    echo "  root filesystem: ${used_pct}% used, ${avail_gb} GB free, inodes ${inode_pct}%"
  else
    echo "  root filesystem: NOT CAPTURED"
  fi
  echo "  local backup dirs (/home/admin_backups, /home/backup, /backup): ${backup_gb} GB (${share}% of everything in use)"

  # --- did the disk actually break the services? ---
  local enospc_lines console_enospc=0 console_enospc_label="no" svc_down="" enospc_searched=0
  local enospc_markers=0 enospc_skipped=0 enospc_old=0 enospc_undated=0 enospc_unreadable=0
  # SKIPPED_OLD counts as a marker even though it names a file that was not searched. A
  # capture where every log fell outside the window is still a modern capture, and its
  # SKIPPED_OLD lines must not reach the legacy branch below, which would count them as
  # ENOSPC matches and confirm a full disk from nothing but log filenames.
  enospc_markers="$(read_section "$dir" enospc | grep -cE '^(SEARCHED|SKIPPED_OLD|SKIPPED_UNREADABLE) ' || true)"
  enospc_searched="$(read_section "$dir" enospc | grep -c '^SEARCHED ' || true)"
  enospc_skipped="$(read_section "$dir" enospc | grep -c '^SKIPPED_OLD ' || true)"
  enospc_unreadable="$(read_section "$dir" enospc | grep -c '^SKIPPED_UNREADABLE ' || true)"
  if ((enospc_markers > 0)); then
    # '^MATCH ' requires the trailing space, so MATCH_OLD and MATCH_UNDATED are excluded
    # here by construction -- only records dated inside the window are evidence.
    enospc_lines="$(read_section "$dir" enospc | grep -c '^MATCH ' || true)"
    enospc_old="$(read_section "$dir" enospc | grep -c '^MATCH_OLD ' || true)"
    enospc_undated="$(read_section "$dir" enospc | grep -c '^MATCH_UNDATED ' || true)"
    # Printed lines are capped per class, so counting them undercounts a busy log. TOTALS
    # carries the real figures; prefer it wherever the capture provides it, so a verdict
    # never turns on how much of the evidence fitted in the capture.
    local totals
    totals="$(read_section "$dir" enospc | grep -m1 '^TOTALS ' || true)"
    if [[ -n "$totals" ]]; then
      enospc_lines="$(sed -n 's/.*in_window=\([0-9]*\).*/\1/p' <<<"$totals")"
      enospc_old="$(sed -n 's/.*out_of_window=\([0-9]*\).*/\1/p' <<<"$totals")"
      enospc_undated="$(sed -n 's/.*undated=\([0-9]*\).*/\1/p' <<<"$totals")"
    fi
  else
    # Capture predates the SEARCHED/MATCH markers: every line is a match, and there is
    # no way to tell whether the logs existed. Treated as "cannot rule out" below.
    enospc_lines="$(read_section "$dir" enospc | grep -c . || true)"
  fi
  if read_section "$dir" console_output | grep -qiE "no space left|ENOSPC"; then
    console_enospc=1
    console_enospc_label="yes"
  fi
  while IFS='=' read -r svc state; do
    [[ -z "${svc:-}" ]] && continue
    case "$state" in
      failed | inactive) svc_down="${svc_down} ${svc}" ;;
    esac
  done < <(read_section "$dir" services)

  echo
  echo "-- Did a full disk break the services? --"
  if ((enospc_searched > 0)); then
    echo "  ENOSPC / 'no space left' lines in host logs: ${enospc_lines:-0} (searched ${enospc_searched} log file(s), skipped ${enospc_skipped} written outside the window)"
  elif ((enospc_markers > 0)); then
    echo "  ENOSPC / 'no space left' lines in host logs: not searchable (all ${enospc_skipped} log file(s) were written outside the incident window)"
  else
    echo "  ENOSPC / 'no space left' lines in host logs: ${enospc_lines:-0} (capture does not record which logs were searchable)"
  fi
  if ((enospc_old > 0)); then
    echo "  ...plus ${enospc_old} ENOSPC record(s) in those logs dated before the window (a prior incident, not this one)"
  fi
  if ((enospc_undated > 0)); then
    echo "  ...plus ${enospc_undated} ENOSPC record(s) whose timestamp could not be parsed -- read them by hand"
  fi
  if ((enospc_unreadable > 0)); then
    echo "  ...and ${enospc_unreadable} in-window log(s) could not be read at all (missing decompressor)"
  fi
  echo "  same in EC2 console output (survives a wedged userland): ${console_enospc_label}"
  echo "  services not active now:${svc_down:- none}"

  # --- which defect fired? ---
  local claimed_clean=0 stale_dirs=0 upload_errors=0 unverified=0
  claimed_clean="$(read_section "$dir" hook_log | grep -c 'cleaned local system backup dirs' || true)"
  # A dated directory is stale if nothing has touched it for hours, not because its name
  # has a date in it. During a system backup today's directory is present and being
  # written, and counting it as stale both invents a defect-2 signature and cancels the
  # in-flight-upload guard below -- so the one capture most likely to be taken during a
  # live backup was the one guaranteed to be misread.
  local dated_marked=0 active_dirs=0 stale_age_known=1
  dated_marked="$(read_section "$dir" backup_listing | grep -c '^DATED_DIR ' || true)"
  if ((${dated_marked:-0} > 0)); then
    stale_dirs="$(read_section "$dir" backup_listing \
      | awk -v t="$ACTIVE_DIR_MAX_AGE_S" '/^DATED_DIR /{ split($2, a, "="); if (a[2] + 0 > t) n++ } END { print n + 0 }')"
    active_dirs="$(read_section "$dir" backup_listing \
      | awk -v t="$ACTIVE_DIR_MAX_AGE_S" '/^DATED_DIR /{ split($2, a, "="); if (a[2] + 0 <= t) n++ } END { print n + 0 }')"
  else
    # A capture from before the collector emitted ages. The name count is all there is.
    stale_age_known=0
    stale_dirs="$(read_section "$dir" backup_listing | grep -cE '[0-9]{2}-[0-9]{2}-[0-9]{2}$' || true)"
  fi
  upload_errors="$(read_section "$dir" hook_log | grep -cE 'ERROR|rc=[1-9]' || true)"
  unverified="$(read_section "$dir" hook_log | grep -c 'not verified in S3' || true)"

  echo
  echo "-- Which defect fired? --"
  echo "  log lines claiming 'cleaned local system backup dirs': ${claimed_clean:-0}"
  if ((stale_age_known == 1)); then
    echo "  dated backup directories left behind (idle > $((ACTIVE_DIR_MAX_AGE_S / 3600))h): ${stale_dirs:-0}"
    echo "  dated backup directories still being written: ${active_dirs:-0}"
  else
    echo "  dated backup directories still present locally: ${stale_dirs:-0} (age not recorded by this capture)"
  fi
  echo "  ERROR / non-zero rclone lines in the hook log: ${upload_errors:-0}"
  echo "  'not verified in S3' lines (only the fixed hook emits these): ${unverified:-0}"

  # --- is the running hook even the repo's? ---
  local installed_hash installed_desc="not captured"
  installed_hash="$(read_section "$dir" installed_hashes | awk '/all_backups_post\.sh/ {print $1; exit}')"
  if [[ "${installed_hash:-}" == "MISSING" ]]; then
    # Distinct from "stale" and far worse: with no hook at all, DirectAdmin writes
    # backups to local disk and nothing ever uploads or removes them.
    installed_desc="NOT INSTALLED on this host"
  elif [[ -n "${installed_hash:-}" ]]; then
    installed_desc="$(identify_installed_hook "$installed_hash")"
  fi
  echo
  echo "-- Is the running hook the repo's? --"
  echo "  installed all_backups_post.sh is ${installed_desc}"

  ##############################################################################
  # Verdict
  ##############################################################################
  local disk_verdict="INCONCLUSIVE" cause_verdict="INCONCLUSIVE" rc=2
  local -a notes=()

  if ((console_enospc == 1)) || ((${enospc_lines:-0} > 0)); then
    disk_verdict="CONFIRMED"
    notes+=("A service logged ENOSPC, which is direct evidence the volume filled and writes failed -- not an inference from disk usage.")
  elif ((enospc_unreadable > 0)); then
    # A log inside the window that nothing could open is not evidence of absence, and a
    # rotation is where an incident's last lines usually are.
    disk_verdict="INCONCLUSIVE"
    notes+=("${enospc_unreadable} log file(s) inside the incident window could not be read because the host lacks the decompressor for them, so ENOSPC can be neither confirmed nor ruled out. Install it (usually gzip) and re-capture, or copy those rotations off and grep them elsewhere.")
  elif ((enospc_undated > 0)); then
    # Neither branch below is honest here. Confirming would resurrect the bias the window
    # was added to remove; refuting would print "not one service logged ENOSPC" while the
    # capture holds ENOSPC lines nobody has dated. Say what is actually known.
    disk_verdict="INCONCLUSIVE"
    notes+=("${enospc_undated} ENOSPC record(s) matched but carry no timestamp this script can parse, so they cannot be placed inside or outside the incident window. Read them in the 'enospc' section of the capture: if any is from the incident, the disk verdict is CONFIRMED; if all are older, re-run --analyze once they are excluded.")
  elif ((enospc_searched > 0)) && ((used_pct >= FULL_PCT)); then
    # A high-water mark is not an outage. This branch exists because the 2026-09-06
    # capture hit exactly this shape -- 99% used, zero ENOSPC across every log on the
    # box -- and an earlier version of this script called it CONSISTENT, which is the
    # diagnostic agreeing with the hypothesis it was written to test. The disk was a
    # red herring; the host had run at 99% for weeks and died of memory exhaustion.
    disk_verdict="NOT SUPPORTED"
    notes+=("The volume is ${used_pct}% used, but ${enospc_searched} log file(s) were searched and not one service logged ENOSPC inside the incident window. A nearly-full disk that no service ever failed a write against did not cause an outage. Unless the space was reclaimed before this capture, look elsewhere -- start with memory: 'sar -r -f /var/log/sa/saDD' and 'sar -S -f ...' around the failure window.")
  elif ((used_pct >= FULL_PCT)); then
    disk_verdict="CONSISTENT"
    notes+=("The volume is still ${used_pct}% used, and this capture has no log covering the incident window to search, so ENOSPC can be neither confirmed nor ruled out. Either the capture predates the searchability markers, or every log had already rotated out of the window. Re-capture closer to the event, with a current version of this script, to settle it.")
  elif ((used_pct >= 0)); then
    disk_verdict="NOT SUPPORTED"
    notes+=("The volume is only ${used_pct}% used and nothing logged ENOSPC. Either the space was already reclaimed before this capture, or the outage had a different cause.")
  fi

  local backup_gb_int
  backup_gb_int="$(awk -v k="$backup_kb" 'BEGIN {printf "%d", k/1048576}')"
  # A big local footprint means cleanup failed only if cleanup has already had its turn.
  # During a backup, or while rclone is still uploading one, tens of gigabytes on disk is
  # the system working correctly -- the hook deletes after the upload verifies, so the
  # files are supposed to be there. The collector has recorded pgrep for rclone all along
  # and nothing read it, so a capture taken mid-upload confirmed a cleanup failure that
  # had not happened, and could pair that with an ENOSPC hit to exit 0.
  local rclone_active=0
  if read_section "$dir" rclone_running | grep -qvE '^\(none\)$|^[[:space:]]*$'; then
    rclone_active=1
  fi

  if ((backup_gb_int >= BACKUP_GB_SIGNIFICANT)) || ((share >= BACKUP_SHARE_PCT)); then
    # With ages recorded, "no directory has been idle for hours" is real evidence that
    # nothing finished badly. Without them, a dated directory could be today's in-progress
    # one or last week's leftover, and a capture that cannot tell the difference should not
    # be the thing that convicts the hook.
    local no_failed_run=0
    if ((stale_age_known == 1)); then
      ((${stale_dirs:-0} == 0)) && no_failed_run=1
    else
      no_failed_run=1
    fi
    if ((rclone_active == 1)) && ((no_failed_run == 1)) && ((${upload_errors:-0} == 0)); then
      # Nothing here says a run finished badly: no stale dated directories, no upload
      # errors, and an upload in flight that explains the footprint.
      cause_verdict="INCONCLUSIVE"
      notes+=("Local backups account for ${backup_gb} GB (${share}% of used space), but rclone is running in this capture and nothing shows a completed run that failed -- no stale dated directories, no upload errors. A backup mid-upload is supposed to occupy disk; cleanup happens after verification. Re-capture once 'pgrep -a rclone' is empty before concluding the hook is at fault.")
    else
      cause_verdict="CONFIRMED"
      notes+=("Local backups account for ${backup_gb} GB (${share}% of used space), so the backup hook's cleanup is the thing that failed.")
    fi
    if ((${claimed_clean:-0} > 0)) && ((${stale_dirs:-0} > 0)); then
      notes+=("Defect 2 signature present: the log claims it cleaned /home/backup while dated directories are still there. That is the bug that freed nothing while exiting 0.")
    fi
    if ((${upload_errors:-0} > 0)); then
      notes+=("Defect 1 signature present: upload errors in the hook log, which under the old 'set -e' aborted the run before any cleanup.")
    fi
  elif ((backup_kb > 0)); then
    cause_verdict="NOT SUPPORTED"
    notes+=("Local backups are only ${backup_gb} GB (${share}% of used space), so they are not what filled the volume. Check 'top_dirs' in this capture for the real consumer before acting on the incident doc.")
  fi

  if [[ "$installed_desc" == "NOT INSTALLED on this host" ]]; then
    notes+=("The backup hook is not installed here at all, so nothing has ever uploaded or cleaned up these backups. That alone fills the volume, and it needs 'install_da_vhost_listen.sh --install' regardless of what else this capture shows.")
  elif [[ "$installed_desc" == unidentified* ]]; then
    # Not evidence either way -- say so rather than implying the host is stale.
    notes+=("Could not tell which version of the hook is installed (${installed_desc}). Re-run --analyze somewhere with sha256sum or shasum, or run 'install_da_vhost_listen.sh --verify' on the host.")
  elif [[ "$installed_desc" != "current (matches this checkout)" && "$installed_desc" != "not captured" ]]; then
    notes+=("The hook running on this host is ${installed_desc}. Any fix in main is not in effect until 'install_da_vhost_listen.sh --install' is run here.")
  fi

  # Truncation invalidates absence, not presence. An ENOSPC line that did arrive is still
  # an ENOSPC line, so a confirmation stands. But "nothing logged ENOSPC" cannot be
  # asserted about a stream that was cut off, and neither can the CONSISTENT reading that
  # pairs with a CONFIRMED cause to exit 0 -- the script's most decisive answer, which is
  # exactly what this capture is least entitled to give.
  local truncated=0
  if [[ -f "${dir}/capture-truncated" ]] && [[ "$disk_verdict" != "CONFIRMED" ]]; then
    truncated=1
    disk_verdict="INCONCLUSIVE"
    notes+=("This capture has no END marker, so SSM cut it off mid-stream. Sections are written in order and 'enospc' is near the end, so the part most likely missing is the part that decides this question, while the disk usage and backup sizes that appear to support it arrived early and survived. Re-capture before concluding anything: collect fewer sections, or pull the log tail separately.")
  fi

  echo
  echo "================================================================"
  echo "VERDICT"
  echo "  Full disk explains the outage:      ${disk_verdict}"
  echo "  Backup cleanup is why it filled:    ${cause_verdict}"
  echo "================================================================"
  local n
  for n in "${notes[@]}"; do
    echo "  - ${n}"
  done

  if [[ "$disk_verdict" == "NOT SUPPORTED" || "$cause_verdict" == "NOT SUPPORTED" ]]; then
    rc=1
  elif [[ "$cause_verdict" == "CONFIRMED" && "$disk_verdict" == "CONFIRMED" ]]; then
    rc=0
  fi
  # CONSISTENT used to be enough for rc=0 alongside a confirmed cause. But CONSISTENT is
  # what this script says when it had no log covering the window to search -- its own note
  # spells out that ENOSPC can be neither confirmed nor ruled out. Exiting 0 on that turned
  # "we could not check" into "the hypothesis holds" for any caller reading the status
  # rather than the report, and a nearly-full disk plus a large backup footprint is the
  # easiest state on earth to reach without an outage. Only a service that actually logged
  # ENOSPC earns a decisive 0.
  # Applied last so nothing above can hand a truncated capture a decisive exit status. A
  # confirmation from evidence that did arrive keeps its own rc; everything else is 2.
  ((truncated == 1)) && rc=2

  echo
  echo "Capture kept at: ${dir}"
  echo "Runbook: aws/docs/2026-09-06-primary-outage.md"
  return "$rc"
}

##############################################################################

if [[ -n "$ANALYZE_DIR" ]]; then
  analyze "$ANALYZE_DIR"
  exit $?
fi

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="/tmp/disk-full-evidence-$(date -u +%Y%m%dT%H%M%SZ)"
fi

if ! collect "$OUT_DIR"; then
  echo "Collection failed; nothing to analyse." >&2
  exit 3
fi
echo
analyze "$OUT_DIR"
exit $?
