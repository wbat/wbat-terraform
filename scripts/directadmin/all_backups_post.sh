#!/bin/bash
# DirectAdmin post-backup hook: upload admin + system backups to S3, then free local disk.
# Install: /usr/local/directadmin/scripts/custom/all_backups_post.sh
# Also symlink or copy to system_backup_post.sh so system backups trigger the same upload.
set -euo pipefail

ADMIN_DIR="/home/admin_backups"
SYSTEM_ROOT="/home/backup"
BUCKET="wbat-tellerstech-directadmin-backups-708113892725"
HOST="$(hostname -s)"
DATE="$(date +%F)"
DEST="s3backup:${BUCKET}/${HOST}/${DATE}/"
LOG="/var/log/da-backup-s3.log"

RCLONE_OPTS=(
  --s3-no-check-bucket
  --checksum
  --transfers 4
  --checkers 8
  --log-file "$LOG"
  --log-level INFO
)

log() { echo "$(date -Iseconds) $*" >>"$LOG"; }

upload_admin() {
  [[ -d "$ADMIN_DIR" ]] || return 0
  local count
  count="$(find "$ADMIN_DIR" \( -name '*.tar.zst' -o -name '*.tar.gz' \) -type f 2>/dev/null | wc -l)"
  [[ "$count" -gt 0 ]] || return 0
  log "upload admin_backups ($count archive files) -> $DEST"
  rclone copy "$ADMIN_DIR" "$DEST" "${RCLONE_OPTS[@]}"
}

upload_system() {
  [[ -d "$SYSTEM_ROOT" ]] || return 0
  local sys_dir="${SYSTEM_ROOT}/$(date +%m-%d-%y)"
  if [[ ! -d "$sys_dir" ]]; then
    sys_dir="$(find "$SYSTEM_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2- || true)"
  fi
  [[ -n "${sys_dir:-}" && -d "$sys_dir" ]] || return 0
  log "upload system backup $sys_dir -> $DEST"
  rclone copy "$sys_dir" "$DEST" "${RCLONE_OPTS[@]}"
}

cleanup_admin_local() {
  [[ -d "$ADMIN_DIR" ]] || return 0
  find "$ADMIN_DIR" \( -name '*.tar.zst' -o -name '*.tar.gz' \) -type f -delete
  find "$ADMIN_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec rm -rf {} +
  log "cleaned local $ADMIN_DIR (tar.zst + staging subdirs)"
}

cleanup_system_local() {
  [[ -d "$SYSTEM_ROOT" ]] || return 0
  local sys_dir="${SYSTEM_ROOT}/$(date +%m-%d-%y)"
  [[ -d "$sys_dir" ]] && rm -rf "$sys_dir"
  find "$SYSTEM_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
  log "cleaned local system backup dirs under $SYSTEM_ROOT"
}

upload_admin
upload_system
cleanup_admin_local
cleanup_system_local
