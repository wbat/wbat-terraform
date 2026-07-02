#!/bin/bash
# DirectAdmin post-hook for System Backup (apache/bind/custom/mysql under /home/backup).
# Reuses the same S3 upload + local cleanup as admin backups.
exec /usr/local/directadmin/scripts/custom/all_backups_post.sh
