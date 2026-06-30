#!/usr/bin/env bash
# Live/final rsync for primary shrink migration (OLD -> NEW)
# Run on OLD server as root. Avoids -X (SELinux xattrs); run restorecon on NEW after cutover.
set -euo pipefail

NEW_IP="${NEW_IP:-172.30.0.71}"
RSYNC_USER="${RSYNC_USER:-ec2-user}"
RSYNC_SSH="${RSYNC_SSH:-ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30}"
LOG="${LOG:-/var/log/shrink-rsync-live.log}"

RSYNC_EXCLUDES=(
  --exclude=/proc/*
  --exclude=/sys/*
  --exclude=/dev/*
  --exclude=/run/*
  --exclude=/tmp/*
  --exclude=/mnt/*
  --exclude=/media/*
  --exclude=/lost+found
  --exclude=/swapfile
  --exclude=/home/ec2-user/.ssh/authorized_keys
)

# -aHAxx (no capital -X): skips SELinux security.selinux xattrs that fail on NEW receiver.
# After cutover on NEW: restorecon -Rv /home /var/www /usr/local/directadmin
RSYNC_FLAGS=(-aHAxx --numeric-ids --info=progress2 --rsync-path="sudo rsync")

echo "=== rsync start $(date -Is) -> ${RSYNC_USER}@${NEW_IP} ===" | tee -a "$LOG"
rsync "${RSYNC_FLAGS[@]}" -e "$RSYNC_SSH" "${RSYNC_EXCLUDES[@]}" / "${RSYNC_USER}@${NEW_IP}:/" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
echo "=== rsync end $(date -Is) exit=$rc ===" | tee -a "$LOG"
# exit 23 = partial (often xattr noise with old runs); 0 = clean
if [[ "$rc" -eq 0 || "$rc" -eq 23 ]]; then
  echo "DONE $(date -Is) exit=$rc" >> "$LOG"
fi
exit "$rc"
