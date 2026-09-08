#!/bin/bash
# Copy large, static website media to S3 so it can be excluded from the nightly
# DirectAdmin account backup, and refuse to let it be excluded until that copy has been
# verified.
#
# Install: /usr/local/sbin/sync-site-media.sh, driven by /etc/cron.d/da-site-media.
#
# Why this exists. `teller` is 54 GB and needs roughly twice that in free staging space
# during a backup, against 58 GB free -- so it has had no account backup since 2026-07-02
# and no amount of rescheduling changes that, because the constraint is peak space during
# one run. About 34 GB of the account is web media: two `gallery` directories, some video
# directories, and a document archive. Measured on 2026-09-08, comsatlegacy.com's 17.3 GB
# gallery had zero of its 33,319 files change in 90 days and its newest file was 266 days
# old; its videos had not changed in six years. Copying that to S3 every night is what
# made the account unbackuppable, and it was buying nothing, because the bytes were
# identical every time.
#
# Splitting it fixes both: the account archive drops to something that fits the disk that
# exists, and the media gets a copy that is updated incrementally instead of rewritten.
#
# The dangerous part is the ordering, so it is enforced rather than documented. Excluding
# a path from the account backup makes the S3 copy the only off-host copy of live site
# content. If the exclusion lands first, or lands after a failed sync, the most
# irreplaceable data in the account is backed up nowhere and nothing says so -- which is
# the failure this whole runbook exists because of. So --write-exclusions will not write
# anything unless a receipt from this script says the exact same set of paths was copied
# and read back, recently, and has not changed since.
#
# Three things this script will not do, by construction:
#
#   1. Delete anything, locally or in S3. It copies. Files removed from the host stay in
#      the archive, which is the direction an archive should fail in. The IAM role has no
#      s3:DeleteObject on this bucket either, so it is not merely a convention here.
#   2. Trust its own upload. Every run verifies with checksums over the whole path set,
#      and --deep-verify reads the bytes back rather than comparing metadata.
#   3. Stay quiet when exclusions are in place and verification has stopped passing.
#      That combination means live data is unprotected, and it alerts on every run.
#
# Paths are overridable by environment variable so prove_site_media.sh can exercise this
# without root, S3, or DirectAdmin.

set -uo pipefail
# Deliberately not `set -e`, matching the sibling scripts: a failure on one account must
# still produce a summary and an alert covering the others.

HOME_ROOT="${SITE_MEDIA_HOME:-/home}"
MANIFEST="${SITE_MEDIA_MANIFEST:-/etc/da-vhost-listen/site-media.conf}"
CONFIG="${SITE_MEDIA_CONF:-/etc/da-vhost-listen/vhost-listen.conf}"
LOG="${SITE_MEDIA_LOG:-/var/log/da-site-media.log}"
LOCK="${SITE_MEDIA_LOCK:-/var/lock/da-site-media.lock}"
STATE_DIR="${SITE_MEDIA_STATE:-/var/lib/da-ops/site-media}"
EXCLUDE_NAME=".backup_exclude_paths"

# The archive bucket, from aws/global/s3-site-media-archive.tf. Set in the config file.
BUCKET="${SITE_MEDIA_BUCKET:-}"
REGION="${SITE_MEDIA_REGION:-us-east-1}"

# An rclone connection string rather than a named remote, so this needs no rclone.conf
# entry and cannot pick up the wrong credentials. env_auth makes it use the instance
# role, which is what carries the archive-bucket grant -- the `s3backup` remote used by
# the backup hook is an IAM user scoped to the backup bucket and cannot write here.
RCLONE_REMOTE_OPTS="${SITE_MEDIA_REMOTE_OPTS:-:s3,provider=AWS,env_auth=true,region=REGION_PLACEHOLDER:}"

# How stale a receipt may be before --write-exclusions refuses it. A receipt proves the
# copy was good when it was written; a month-old one proves very little about now.
RECEIPT_MAX_AGE_S="${SITE_MEDIA_RECEIPT_MAX_AGE_S:-604800}" # 7 days

# Defensive bounds on the manifest, for the same reason the batch estimator has them: it
# is a file in a fixed location that something else might one day write.
MANIFEST_MAX_BYTES="${SITE_MEDIA_MANIFEST_MAX_BYTES:-65536}"

RCLONE="${SITE_MEDIA_RCLONE:-rclone}"
HEALTH_ALERT_TO=""
HOST="$(hostname -f 2>/dev/null || hostname)"

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

# Same guards as the sibling scripts: an address that can never receive mail is reported
# as broken alerting rather than logged as a successful send.
alert() {
  local subject="$1" body="$2"
  local dest="${HEALTH_ALERT_TO}"
  local dest_lc="${dest,,}"
  local mail_out mail_rc=0

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

  mail_out="$(printf '%s\n' "$body" | mail -s "$subject" "$dest" 2>&1)" || mail_rc=$?
  if [[ $mail_rc -eq 0 ]]; then
    log "OK alert mailed to ${dest}"
  else
    log "ERROR alert submission FAILED (mail rc=${mail_rc}) to ${dest}: ${mail_out:-no output}"
  fi
}

remote_base() {
  local opts="${RCLONE_REMOTE_OPTS//REGION_PLACEHOLDER/$REGION}"
  printf '%s%s' "$opts" "$BUCKET"
}

# Read the manifest into MANIFEST_USERS and MANIFEST_PATHS (parallel arrays).
#
# Every rejection below is a case where accepting the line would silently archive or
# exclude the wrong thing. Absolute paths and `..` escape the account. A trailing slash
# is rejected because these same strings are written into .backup_exclude_paths, and GNU
# tar 1.35 does not exclude a directory given with one -- the account backup would then
# still contain the media this script exists to take out of it, and the size gate would
# have been told otherwise.
MANIFEST_USERS=()
MANIFEST_PATHS=()
read_manifest() {
  local line user path size

  if [[ ! -f "$MANIFEST" ]]; then
    log "ERROR no manifest at ${MANIFEST}"
    return 1
  fi
  if [[ -L "$MANIFEST" ]]; then
    log "ERROR manifest ${MANIFEST} is a symlink; refusing to read it"
    return 1
  fi
  size="$(stat -c %s "$MANIFEST" 2>/dev/null || echo 0)"
  if ((size > MANIFEST_MAX_BYTES)); then
    log "ERROR manifest ${MANIFEST} is ${size} bytes, over the ${MANIFEST_MAX_BYTES} limit"
    return 1
  fi

  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    read -r user path <<<"$line"
    if [[ -z "${user:-}" || -z "${path:-}" ]]; then
      log "NOTE ignoring malformed manifest line: ${line}"
      continue
    fi
    if [[ "$path" == /* ]]; then
      log "NOTE ignoring absolute path for ${user}: ${path} (paths are relative to the home)"
      continue
    fi
    if [[ "$path" == */ ]]; then
      log "NOTE ignoring ${user} ${path}: a trailing slash is not honoured by tar --exclude-from"
      continue
    fi
    if [[ "$path" == *..* ]]; then
      log "NOTE ignoring ${user} ${path}: contains .."
      continue
    fi
    if [[ ! -d "${HOME_ROOT}/${user}" ]]; then
      log "NOTE ignoring ${user} ${path}: no home at ${HOME_ROOT}/${user}"
      continue
    fi

    MANIFEST_USERS+=("$user")
    MANIFEST_PATHS+=("$path")
  done <"$MANIFEST"

  if ((${#MANIFEST_USERS[@]} == 0)); then
    log "ERROR manifest ${MANIFEST} yielded no usable entries"
    return 1
  fi
  return 0
}

manifest_users_unique() {
  printf '%s\n' "${MANIFEST_USERS[@]}" | sort -u
}

paths_for_user() {
  local want="$1" i
  for i in "${!MANIFEST_USERS[@]}"; do
    [[ "${MANIFEST_USERS[$i]}" == "$want" ]] && printf '%s\n' "${MANIFEST_PATHS[$i]}"
  done
}

receipt_path() { printf '%s/%s.receipt' "$STATE_DIR" "$1"; }

# A receipt is only meaningful if it describes the same work we are about to rely on, so
# it records the path set it covers and is compared against the manifest, not just dated.
write_receipt() {
  local user="$1" files="$2" bytes="$3" mode="$4"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  {
    printf 'verified_at=%s\n' "$(date -Iseconds)"
    printf 'verified_epoch=%s\n' "$(date +%s)"
    printf 'bucket=%s\n' "$BUCKET"
    printf 'method=%s\n' "$mode"
    printf 'files=%s\n' "$files"
    printf 'bytes=%s\n' "$bytes"
    printf 'paths_sha256=%s\n' "$(paths_for_user "$user" | sort | sha256sum | awk '{print $1}')"
    paths_for_user "$user" | sort | sed 's/^/path=/'
  } >"$(receipt_path "$user")"
  chmod 600 "$(receipt_path "$user")" 2>/dev/null || true
}

# Returns 0 only if the receipt is present, recent, from this bucket, and covers exactly
# the paths the manifest currently asks for. Any drift between the two means the receipt
# is evidence about a different question.
receipt_is_current() {
  local user="$1" r age now want have
  r="$(receipt_path "$user")"
  [[ -f "$r" ]] || { echo "no receipt at ${r}"; return 1; }

  local verified_epoch bucket paths_sha
  verified_epoch="$(sed -n 's/^verified_epoch=//p' "$r" | head -1)"
  bucket="$(sed -n 's/^bucket=//p' "$r" | head -1)"
  paths_sha="$(sed -n 's/^paths_sha256=//p' "$r" | head -1)"

  now="$(date +%s)"
  age=$((now - ${verified_epoch:-0}))
  if ((age > RECEIPT_MAX_AGE_S)); then
    echo "receipt is ${age}s old, over the ${RECEIPT_MAX_AGE_S}s limit"
    return 1
  fi
  if [[ "$bucket" != "$BUCKET" ]]; then
    echo "receipt is for bucket ${bucket}, not ${BUCKET}"
    return 1
  fi
  want="$(paths_for_user "$user" | sort | sha256sum | awk '{print $1}')"
  have="$paths_sha"
  if [[ "$want" != "$have" ]]; then
    echo "receipt covers a different set of paths than the manifest asks for"
    return 1
  fi
  return 0
}

exclusions_in_place() {
  local user="$1" f
  f="${HOME_ROOT}/${user}/${EXCLUDE_NAME}"
  [[ -s "$f" ]]
}

# Copy one account's paths. rclone copy never deletes at the destination; that is the
# whole point and it is why this is not `rclone sync`.
copy_user() {
  local user="$1" rc=0 p src dst out
  while IFS= read -r p; do
    src="${HOME_ROOT}/${user}/${p}"
    dst="$(remote_base)/${user}/${p}"
    if [[ ! -e "$src" ]]; then
      log "ERROR ${user}: ${p} does not exist on disk"
      rc=1
      continue
    fi
    log "copying ${user}/${p}"
    if ! out="$("$RCLONE" copy "$src" "$dst" --checksum --transfers 8 --stats-one-line --stats 5m 2>&1)"; then
      log "ERROR ${user}: copy of ${p} failed: ${out}"
      rc=1
      continue
    fi
    [[ -n "$out" ]] && log "  ${out}"
  done < <(paths_for_user "$user")
  return $rc
}

# One-way check: every local file must exist in S3 with a matching checksum. One-way is
# correct here because the archive deliberately keeps files the host no longer has, so
# extra objects at the destination are expected and are not a failure.
verify_user() {
  local user="$1" deep="$2" rc=0 p src dst out args
  args=(check --one-way --checksum)
  [[ "$deep" == "yes" ]] && args=(check --one-way --download)

  while IFS= read -r p; do
    src="${HOME_ROOT}/${user}/${p}"
    dst="$(remote_base)/${user}/${p}"
    [[ -e "$src" ]] || { rc=1; continue; }
    if ! out="$("$RCLONE" "${args[@]}" "$src" "$dst" 2>&1)"; then
      log "ERROR ${user}: verification of ${p} FAILED: $(printf '%s' "$out" | tail -5)"
      rc=1
      continue
    fi
    log "verified ${user}/${p}"
  done < <(paths_for_user "$user")
  return $rc
}

size_of_user() {
  local user="$1" p files=0 bytes=0 f b
  while IFS= read -r p; do
    [[ -e "${HOME_ROOT}/${user}/${p}" ]] || continue
    f="$(find "${HOME_ROOT}/${user}/${p}" -type f 2>/dev/null | wc -l)"
    b="$(du -sb "${HOME_ROOT}/${user}/${p}" 2>/dev/null | cut -f1)"
    files=$((files + f))
    bytes=$((bytes + ${b:-0}))
  done < <(paths_for_user "$user")
  printf '%s %s' "$files" "$bytes"
}

do_list() {
  local user p b
  printf '%-12s %10s  %s\n' "ACCOUNT" "SIZE" "PATH"
  while IFS= read -r user; do
    while IFS= read -r p; do
      if [[ -e "${HOME_ROOT}/${user}/${p}" ]]; then
        b="$(du -sh "${HOME_ROOT}/${user}/${p}" 2>/dev/null | cut -f1)"
      else
        b="MISSING"
      fi
      printf '%-12s %10s  %s\n' "$user" "$b" "$p"
    done < <(paths_for_user "$user")
  done < <(manifest_users_unique)
  printf '\nBucket: %s\n' "${BUCKET:-<unset: set SITE_MEDIA_BUCKET in ${CONFIG}>}"
}

do_write_exclusions() {
  local user rc=0 reason f tmp
  while IFS= read -r user; do
    if ! reason="$(receipt_is_current "$user")"; then
      log "REFUSING to write exclusions for ${user}: ${reason}"
      log "  run a successful --sync first; excluding unverified paths is the failure this guards against"
      rc=1
      continue
    fi
    f="${HOME_ROOT}/${user}/${EXCLUDE_NAME}"
    tmp="${f}.tmp.$$"
    if ! paths_for_user "$user" | sort >"$tmp" 2>/dev/null; then
      log "ERROR ${user}: could not write ${tmp}"
      rc=1
      continue
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    chown "${user}:${user}" "$tmp" 2>/dev/null || true
    if mv "$tmp" "$f"; then
      log "OK wrote $(wc -l <"$f") exclusion path(s) to ${f}"
    else
      log "ERROR ${user}: could not install ${f}"
      rm -f "$tmp" 2>/dev/null || true
      rc=1
    fi
  done < <(manifest_users_unique)
  return $rc
}

do_sync() {
  local deep="$1" rc=0 user copied verified files bytes stats
  local failed=() ok=()

  while IFS= read -r user; do
    copied=0
    verified=0
    copy_user "$user" || copied=1
    verify_user "$user" "$deep" || verified=1

    if ((copied == 0 && verified == 0)); then
      stats="$(size_of_user "$user")"
      read -r files bytes <<<"$stats"
      write_receipt "$user" "$files" "$bytes" "$([[ "$deep" == yes ]] && echo download || echo checksum)"
      log "OK ${user}: ${files} file(s), ${bytes} bytes copied and verified"
      ok+=("$user")
    else
      failed+=("$user")
      rc=1
      # The dangerous state, and the reason this is an alert rather than a log line: the
      # account backup is already skipping these paths, so a failed sync means live site
      # content currently has no off-host copy at all.
      if exclusions_in_place "$user"; then
        alert "Site media archive FAILED for ${user} on ${HOST} -- content is unprotected" \
          "$(printf '%s\n' \
            "${user} has ${EXCLUDE_NAME} in place, so these paths are excluded from the" \
            "nightly DirectAdmin account backup. This run did not manage to copy and" \
            "verify them, which means they are currently backed up nowhere." \
            "" \
            "Paths:" \
            "$(paths_for_user "$user" | sed 's/^/  /')" \
            "" \
            "Recent log:" \
            "$(tail -20 "$LOG" 2>/dev/null | sed 's/^/  /')")"
      fi
    fi
  done < <(manifest_users_unique)

  if ((${#failed[@]} > 0)); then
    log "finished with failures: ${failed[*]}"
  else
    log "finished: ${#ok[@]} account(s) copied and verified"
  fi
  return $rc
}

usage() {
  cat <<'USAGE'
Usage: sync-site-media.sh [--list|--sync|--verify-only|--write-exclusions] [--deep-verify]

  --list               Show the manifest and what each path currently occupies.
  --sync               Copy to S3, verify, and record a receipt. Default.
  --verify-only        Re-verify what is already in S3; do not copy.
  --write-exclusions   Write .backup_exclude_paths for each account in the manifest.
                       Refuses unless a current receipt covers exactly those paths.
  --deep-verify        Verify by reading the bytes back rather than comparing checksums.
                       Slow and worth it once, before the first exclusion is written.

Config: /etc/da-vhost-listen/site-media.conf  (manifest: "<user> <path-relative-to-home>")
        /etc/da-vhost-listen/vhost-listen.conf (SITE_MEDIA_BUCKET, HEALTH_ALERT_TO)
USAGE
}

main() {
  local mode="sync" deep="no"
  while (($# > 0)); do
    case "$1" in
      --list) mode="list" ;;
      --sync) mode="sync" ;;
      --verify-only) mode="verify" ;;
      --write-exclusions) mode="exclusions" ;;
      --deep-verify) deep="yes" ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        echo "unknown argument: $1" >&2
        usage >&2
        return 2
        ;;
    esac
    shift
  done

  read_manifest || return 1

  if [[ "$mode" == "list" ]]; then
    do_list
    return 0
  fi

  if [[ -z "$BUCKET" ]]; then
    log "ERROR SITE_MEDIA_BUCKET is not set (expected in ${CONFIG})"
    return 1
  fi
  if ! command -v "$RCLONE" >/dev/null 2>&1; then
    log "ERROR rclone not found (${RCLONE})"
    return 1
  fi

  case "$mode" in
    exclusions) do_write_exclusions ;;
    verify)
      local rc=0 user
      while IFS= read -r user; do
        verify_user "$user" "$deep" || rc=1
      done < <(manifest_users_unique)
      return $rc
      ;;
    *) do_sync "$deep" ;;
  esac
}

# One run at a time. Two concurrent copies of the same tree are wasteful rather than
# dangerous here -- nothing is deleted -- but two concurrent receipt writes are not.
#
# The guard on the directory rather than a bare `exec 9>"$LOCK" 2>/dev/null` is
# deliberate: a redirection on `exec` with no command applies to the shell for the rest
# of the run, so silencing that line silences every later log call too. The script then
# writes its log file and says nothing to stderr, which is invisible under cron and
# actively misleading by hand.
lock_dir="$(dirname "$LOCK")"
if [[ -d "$lock_dir" && -w "$lock_dir" ]] || [[ -w "$LOCK" ]]; then
  if exec 9>"$LOCK"; then
    if ! flock -n 9; then
      log "another run holds ${LOCK}; exiting"
      exit 0
    fi
  else
    log "NOTE could not open ${LOCK}; running without a lock"
  fi
else
  log "NOTE ${lock_dir} is not writable; running without a lock"
fi

main "$@"
