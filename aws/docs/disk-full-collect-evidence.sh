#!/bin/bash
# Confirm (or refute) the 2026-09-06 root-disk hypothesis with evidence from the box.
#
# aws/docs/disk-full-backup-incident.md analyses the backup hook from the repository and
# concludes that a full root volume explains the outage and that the hook's broken cleanup
# is the likely cause. That analysis had no box access, so two questions were left open:
#
#   1. Did the disk actually fill, and did that break the services?
#   2. Was it the backups -- and if so, which defect fired?
#
# This collects the evidence for both over SSM, saves it as a fixture, and prints a
# verdict. Deliberately read-only: it changes nothing, so it is safe to run before
# recovering the space (and running it after a cleanup will say so rather than mislead).
#
# Usage:
#   ./disk-full-collect-evidence.sh                        # primary, collect + analyse
#   ./disk-full-collect-evidence.sh --host secondary
#   ./disk-full-collect-evidence.sh --profile wbat --out /tmp/capture
#   ./disk-full-collect-evidence.sh --analyze DIR          # offline; no AWS needed
#
# Needs ssm:SendCommand + ssm:GetCommandInvocation and the SSM agent running on the
# instance. --analyze re-reads a previous capture and needs no credentials at all, which
# is also how the verdict logic is testable without a box.
#
# Exit status: 0 = hypothesis confirmed, 1 = contradicted (look elsewhere),
#              2 = inconclusive, 3 = collection failed.

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
du -sk /home/admin_backups /home/backup 2>/dev/null
echo "===SECTION top_dirs==="
du -xk --max-depth=2 / 2>/dev/null | sort -rn | head -25
echo "===SECTION backup_listing==="
echo "--- /home/backup ---"
ls -la /home/backup/ 2>/dev/null
echo "--- /home/admin_backups ---"
ls -la /home/admin_backups/ 2>/dev/null
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
grep -ihE "no space left|ENOSPC|disk full|out of disk" \
  /var/log/messages /var/log/messages-* /var/log/mysqld.log \
  /var/log/mariadb/mariadb.log /var/log/exim/mainlog 2>/dev/null | tail -40
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
    echo "Capture complete: ${out}" >&2
  else
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
  echo "  /home/admin_backups + /home/backup: ${backup_gb} GB (${share}% of everything in use)"

  # --- did the disk actually break the services? ---
  local enospc_lines console_enospc=0 console_enospc_label="no" svc_down=""
  enospc_lines="$(read_section "$dir" enospc | grep -c . || true)"
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
  echo "  ENOSPC / 'no space left' lines in host logs: ${enospc_lines:-0}"
  echo "  same in EC2 console output (survives a wedged userland): ${console_enospc_label}"
  echo "  services not active now:${svc_down:- none}"

  # --- which defect fired? ---
  local claimed_clean=0 stale_dirs=0 upload_errors=0 unverified=0
  claimed_clean="$(read_section "$dir" hook_log | grep -c 'cleaned local system backup dirs' || true)"
  stale_dirs="$(read_section "$dir" backup_listing | grep -cE '[0-9]{2}-[0-9]{2}-[0-9]{2}$' || true)"
  upload_errors="$(read_section "$dir" hook_log | grep -cE 'ERROR|rc=[1-9]' || true)"
  unverified="$(read_section "$dir" hook_log | grep -c 'not verified in S3' || true)"

  echo
  echo "-- Which defect fired? --"
  echo "  log lines claiming 'cleaned local system backup dirs': ${claimed_clean:-0}"
  echo "  dated backup directories still present under /home/backup: ${stale_dirs:-0}"
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
  elif ((used_pct >= FULL_PCT)); then
    disk_verdict="CONSISTENT"
    notes+=("The volume is still ${used_pct}% used. That fits the hypothesis but is not proof the outage was caused by ENOSPC; the log evidence above is what would settle it.")
  elif ((used_pct >= 0)); then
    disk_verdict="NOT SUPPORTED"
    notes+=("The volume is only ${used_pct}% used and nothing logged ENOSPC. Either the space was already reclaimed before this capture, or the outage had a different cause.")
  fi

  local backup_gb_int
  backup_gb_int="$(awk -v k="$backup_kb" 'BEGIN {printf "%d", k/1048576}')"
  if ((backup_gb_int >= BACKUP_GB_SIGNIFICANT)) || ((share >= BACKUP_SHARE_PCT)); then
    cause_verdict="CONFIRMED"
    notes+=("Local backups account for ${backup_gb} GB (${share}% of used space), so the backup hook's cleanup is the thing that failed.")
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
  elif [[ "$cause_verdict" == "CONFIRMED" ]] && [[ "$disk_verdict" == "CONFIRMED" || "$disk_verdict" == "CONSISTENT" ]]; then
    rc=0
  fi

  echo
  echo "Capture kept at: ${dir}"
  echo "Runbook: aws/docs/disk-full-backup-incident.md"
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
