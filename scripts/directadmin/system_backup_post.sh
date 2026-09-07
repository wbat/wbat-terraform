#!/bin/bash
# DirectAdmin post-hook for System Backup (apache/bind/custom/mysql under /backup).
# Reuses the same S3 upload + local cleanup as admin backups; the two events can overlap,
# and all_backups_post.sh takes a lock so the second run waits rather than deleting
# files the first is still uploading.
#
# --event=system is the completion signal for the system tree, and it is only true here.
# The lock cannot supply it: it serialises hook runs, not the backup process writing the
# files, so the admin event can arrive mid-write. Without this flag that run defers the
# directory instead of uploading a fragment and deleting the rest.
exec /usr/local/directadmin/scripts/custom/all_backups_post.sh --event=system
