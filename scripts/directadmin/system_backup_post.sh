#!/bin/bash
# DirectAdmin post-hook for System Backup (apache/bind/custom/mysql under /home/backup).
# Reuses the same S3 upload + local cleanup as admin backups; the two events can overlap,
# and all_backups_post.sh takes a lock so the second run waits rather than deleting
# files the first is still uploading.
exec /usr/local/directadmin/scripts/custom/all_backups_post.sh
