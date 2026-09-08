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
# Markers around the paths this script owns inside .backup_exclude_paths. Everything
# outside them is left alone, so an account that already excludes something else does not
# lose that exclusion when site-media archiving is added.
MANAGED_BEGIN="# BEGIN da-site-media"
MANAGED_END="# END da-site-media"

# Overridable; the live values usually come from CONFIG below. Read after sourcing.
REGION_DEFAULT="us-east-1"

# An rclone connection string rather than a named remote, so this needs no rclone.conf
# entry and cannot pick up the wrong credentials. env_auth makes it use the instance
# role, which is what carries the archive-bucket grant -- the `s3backup` remote used by
# the backup hook is an IAM user scoped to the backup bucket and cannot write here.
RCLONE_REMOTE_OPTS_DEFAULT=":s3,provider=AWS,env_auth=true,region=REGION_PLACEHOLDER:"

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
  # Capture env-provided values first. `source` would otherwise overwrite them, and the
  # contract matching every sibling script is that the environment wins over the file.
  _env_bucket="${SITE_MEDIA_BUCKET-}"
  _env_region="${SITE_MEDIA_REGION-}"
  _env_remote="${SITE_MEDIA_REMOTE_OPTS-}"
  source "$CONFIG"
  [[ -n "$_env_bucket" ]] && SITE_MEDIA_BUCKET="$_env_bucket"
  [[ -n "$_env_region" ]] && SITE_MEDIA_REGION="$_env_region"
  [[ -n "$_env_remote" ]] && SITE_MEDIA_REMOTE_OPTS="$_env_remote"
  unset _env_bucket _env_region _env_remote
fi

# Resolved after sourcing so /etc/da-vhost-listen/vhost-listen.conf can set them.
BUCKET="${SITE_MEDIA_BUCKET:-}"
REGION="${SITE_MEDIA_REGION:-$REGION_DEFAULT}"
RCLONE_REMOTE_OPTS="${SITE_MEDIA_REMOTE_OPTS:-$RCLONE_REMOTE_OPTS_DEFAULT}"
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

# Fingerprint of the on-disk trees a receipt claims to cover: every regular file's
# relative path, size and mtime. Path names alone are not enough -- a file added or
# edited after a successful sync would still match a path-only receipt, and
# --write-exclusions would then exclude bytes that were never copied.
tree_fingerprint() {
  local user="$1" p src
  {
    while IFS= read -r p; do
      src="${HOME_ROOT}/${user}/${p}"
      if [[ ! -e "$src" ]]; then
        printf 'MISSING\t%s\n' "$p"
        continue
      fi
      # %T@ is epoch seconds with a fractional part; enough to notice an overwrite.
      find "$src" -type f -printf '%P\t%s\t%T@\n' 2>/dev/null \
        | LC_ALL=C sort \
        | sed "s|^|${p}/|"
    done < <(paths_for_user "$user")
  } | sha256sum | awk '{print $1}'
}

invalidate_receipt() {
  rm -f "$(receipt_path "$1")" 2>/dev/null || true
}

# A receipt is only meaningful if it describes the same work we are about to rely on, so
# it records the path set, the tree fingerprint, and is compared against both -- not just dated.
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
    printf 'tree_sha256=%s\n' "$(tree_fingerprint "$user")"
    paths_for_user "$user" | sort | sed 's/^/path=/'
  } >"$(receipt_path "$user")"
  chmod 600 "$(receipt_path "$user")" 2>/dev/null || true
}

# Returns 0 only if the receipt is present, recent, from this bucket, covers exactly
# the paths the manifest currently asks for, AND the on-disk trees still match what was
# verified. Any drift means the receipt is evidence about a different question.
receipt_is_current() {
  local user="$1" r age now want have tree_want tree_have
  r="$(receipt_path "$user")"
  [[ -f "$r" ]] || { echo "no receipt at ${r}"; return 1; }

  local verified_epoch bucket paths_sha tree_sha
  verified_epoch="$(sed -n 's/^verified_epoch=//p' "$r" | head -1)"
  bucket="$(sed -n 's/^bucket=//p' "$r" | head -1)"
  paths_sha="$(sed -n 's/^paths_sha256=//p' "$r" | head -1)"
  tree_sha="$(sed -n 's/^tree_sha256=//p' "$r" | head -1)"

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
  if [[ -z "$tree_sha" ]]; then
    echo "receipt has no tree fingerprint (pre-dates content binding); re-run --sync"
    return 1
  fi
  tree_want="$(tree_fingerprint "$user")"
  tree_have="$tree_sha"
  if [[ "$tree_want" != "$tree_have" ]]; then
    echo "on-disk tree has changed since the receipt was written; re-run --sync"
    return 1
  fi
  return 0
}

# True if this account's exclude file contains our managed section, or (for older
# installs) any of the manifest paths. Used to decide whether a failed sync leaves
# content unprotected.
exclusions_in_place() {
  local user="$1" f p
  f="${HOME_ROOT}/${user}/${EXCLUDE_NAME}"
  [[ -s "$f" ]] || return 1
  if grep -qxF "$MANAGED_BEGIN" "$f" 2>/dev/null; then
    return 0
  fi
  while IFS= read -r p; do
    grep -qxF "$p" "$f" 2>/dev/null && return 0
  done < <(paths_for_user "$user")
  return 1
}

# Alert when a failure would leave excluded media with no off-host copy. Used from
# preflight paths that never reach do_sync, because cron discards stdout/stderr.
alert_if_unprotected() {
  local subject="$1" body="$2" any=0 u
  if ((${#MANIFEST_USERS[@]} > 0)); then
    while IFS= read -r u; do
      if exclusions_in_place "$u"; then
        any=1
        break
      fi
    done < <(manifest_users_unique)
  else
    # Manifest unreadable: be conservative and look for any exclude file.
    local f
    for f in "${HOME_ROOT}"/*/"${EXCLUDE_NAME}"; do
      [[ -s "$f" ]] || continue
      any=1
      break
    done
  fi
  ((any)) || return 0
  alert "$subject" "$body"
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
  local user rc=0 reason f tmp line in_managed keep managed
  while IFS= read -r user; do
    if ! reason="$(receipt_is_current "$user")"; then
      log "REFUSING to write exclusions for ${user}: ${reason}"
      log "  run a successful --sync first; excluding unverified paths is the failure this guards against"
      rc=1
      continue
    fi
    f="${HOME_ROOT}/${user}/${EXCLUDE_NAME}"
    if [[ -L "$f" ]]; then
      log "REFUSING to write exclusions for ${user}: ${f} is a symlink"
      rc=1
      continue
    fi
    tmp="${f}.tmp.$$"
    keep="$(mktemp)"
    managed="$(mktemp)"
    paths_for_user "$user" | sort >"$managed"

    # Preserve every existing line that is not inside our managed section and is not one
    # of the paths we are about to write (avoid duplicates). A file with no markers is
    # treated as entirely foreign content -- its lines stay, and our section is appended.
    in_managed=0
    if [[ -f "$f" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$MANAGED_BEGIN" ]]; then
          in_managed=1
          continue
        fi
        if [[ "$line" == "$MANAGED_END" ]]; then
          in_managed=0
          continue
        fi
        ((in_managed)) && continue
        # Drop blank lines and exact duplicates of paths we manage.
        [[ -z "$line" ]] && continue
        grep -qxF "$line" "$managed" 2>/dev/null && continue
        printf '%s\n' "$line" >>"$keep"
      done <"$f"
    fi

    {
      [[ -s "$keep" ]] && cat "$keep"
      printf '%s\n' "$MANAGED_BEGIN"
      cat "$managed"
      printf '%s\n' "$MANAGED_END"
    } >"$tmp"
    rm -f "$keep" "$managed"

    chmod 600 "$tmp" 2>/dev/null || true
    chown "${user}:${user}" "$tmp" 2>/dev/null || true
    if mv "$tmp" "$f"; then
      log "OK wrote $(grep -cvE '^(#|$)' "$f") exclusion path(s) to ${f} (managed section refreshed)"
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
    # Drop any prior receipt before we start. A failed run must not leave a receipt that
    # still looks valid for --write-exclusions; a successful run writes a fresh one.
    invalidate_receipt "$user"
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

  read_manifest || {
    alert_if_unprotected \
      "Site media archive cannot start on ${HOST} -- content may be unprotected" \
      "$(printf '%s\n' \
        "Preflight failed before any copy ran: the manifest at ${MANIFEST} is missing," \
        "unreadable, or yielded no usable entries. Cron discards this script's output," \
        "so without this alert a broken manifest would silently stop the only backup of" \
        "excluded media." \
        "" \
        "Recent log:" \
        "$(tail -20 "$LOG" 2>/dev/null | sed 's/^/  /')")"
    return 1
  }

  if [[ "$mode" == "list" ]]; then
    do_list
    return 0
  fi

  if [[ -z "$BUCKET" ]]; then
    log "ERROR SITE_MEDIA_BUCKET is not set (expected in ${CONFIG})"
    alert_if_unprotected \
      "Site media archive cannot start on ${HOST} -- SITE_MEDIA_BUCKET unset" \
      "$(printf '%s\n' \
        "SITE_MEDIA_BUCKET is not set in ${CONFIG}. Excluded media has no destination," \
        "so the nightly account backup is omitting content that is not being copied anywhere." \
        "" \
        "Set SITE_MEDIA_BUCKET to the site_media_archive_bucket_id Terraform output.")"
    return 1
  fi
  if ! command -v "$RCLONE" >/dev/null 2>&1; then
    log "ERROR rclone not found (${RCLONE})"
    alert_if_unprotected \
      "Site media archive cannot start on ${HOST} -- rclone missing" \
      "rclone (${RCLONE}) is not on PATH. Excluded media cannot be copied or verified."
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
