# Root disk full on the primary — backup cleanup that silently did nothing

**Incident:** 2026-09-06, primary (`server.wbat.net`) went down in the morning; root
volume reported ~99% used.

**Short answer:** yes, a full root volume explains the outage, and the backup hook is the
most likely reason the volume filled. The hook had three defects that let it skip its
local cleanup while writing a success line to its own log. Two of them are reproducible
offline and are fixed in this change; a third made every occurrence silent.

This investigation was done from the repository only — no SSH/SSM session or AWS API
access was available from it. The code defects below are proven by
[`scripts/directadmin/prove_backup_cleanup.sh`](../../scripts/directadmin/prove_backup_cleanup.sh),
which runs the real hook against stubbed rclone. Which one fired on this host is a
question only the box can answer; [Confirm on the box](#confirm-on-the-box) is the
five-minute check, and it matters, because "the disk filled for some other reason" leads
somewhere completely different.

## Why a full disk takes the server down

At 100% on `/` the services on this host fail writes rather than degrade:

- **MySQL/MariaDB** cannot write the InnoDB redo log or temp tables and shuts down or
  refuses connections; every WordPress site returns a database error.
- **Exim** cannot spool, so mail is deferred or bounced.
- **nginx/PHP-FPM** cannot write sockets, session files, or logs; requests 500.
- **DirectAdmin** cannot write its task queue, so the panel and its own cron work stop.

That matches "server went down" better than a crash would: the instance itself stays
running, which is why an EC2-level check would have looked fine.

Nothing would have warned first. The only CloudWatch alarms in this account are the two
billing alarms in [`aws/global/cloudwatch/billing-alarms.tf`](../global/cloudwatch/billing-alarms.tf).
EC2 publishes no filesystem metric without the CloudWatch agent, and that agent is not
installed on these hosts, so disk usage was not monitored anywhere. The first signal
available was the outage.

## Why the disk filled

The root volume is **200 GB** ([`aws/us-east-1/ec2/primary-instance.tf`](../us-east-1/ec2/primary-instance.tf)),
shrunk from the old large volume in the 2026-06-30 cutover. The whole point of
[`scripts/directadmin/all_backups_post.sh`](../../scripts/directadmin/all_backups_post.sh)
is to keep backups off it: DirectAdmin writes them to `/home/admin_backups` and
`/home/backup`, the hook uploads them to S3, then deletes the local copies. The S3 bucket
comment records the scale involved — **390+ GB of weekly backups** used to live on this
volume. A few missed cleanups is all it takes.

Three defects in that hook, in order of how much disk each one costs:

### 1. `set -e` made one transient S3 error skip *all* cleanup

The hook ran `upload_admin`, `upload_system`, `cleanup_admin_local`,
`cleanup_system_local` in that order under `set -euo pipefail`. Any non-zero rclone exit
— a network blip, an expired key, throttling, or the disk being too full to finish
writing an archive — aborted the script before either cleanup.

Two things make that much worse than a single skipped run:

- **It compounds.** Nothing was freed, and the next scheduled backup wrote a fresh set of
  archives on top. Two or three such runs on a 200 GB volume is the whole incident.
- **The units shared a fate.** A failed *system* upload left the *admin* archives on disk
  even though they were already safely in S3.

`/home/admin_backups` also had no age-based backstop, so archives left by a failed run
stayed until a human noticed.

### 2. Cleanup looked for a different directory than the upload had sent

`upload_system` resolved the system backup directory as `/home/backup/$(date +%m-%d-%y)`,
falling back to the newest directory when today's did not exist. `cleanup_system_local`
then **recomputed** `$(date +%m-%d-%y)` with no fallback.

When those two disagreed, cleanup deleted nothing — and said the opposite:

```text
upload system backup /home/backup/09-05-26 -> s3backup:...:/server/2026-09-06/
cleaned local system backup dirs under /home/backup      <-- deleted nothing
```

Exit status 0. Reproduced in proof 2. The two disagree whenever:

- the hook fires after midnight (a large backup easily crosses it), or
- the schedule slipped and today's directory does not exist, so upload used the fallback.

The uploaded directory then sat on disk until the `-mtime +7` sweep collected it a week
later, which on a weekly backup schedule means it was still there when the next one
arrived.

### 3. Nothing alerted, so both of the above were invisible

DirectAdmin discards hook output. The hook mailed nobody and had no disk check, so its
only trace was `/var/log/da-backup-s3.log` — which, per defect 2, could read as a clean
run. That log was also never rotated, and rclone runs at `--log-level INFO` (one line per
uploaded file), so the log itself was quietly consuming the volume it was meant to protect.

### Two further data-loss defects found while fixing the above

Not causes of the outage, but the same code and worth fixing in one pass:

- **Files arriving mid-upload were deleted unverified.** Cleanup re-globbed at delete
  time instead of deleting what was uploaded, so anything DirectAdmin wrote during a long
  upload was destroyed without ever reaching S3 (proof 5).
- **Deletion was never verified against S3.** `rclone copy` exiting 0 was treated as proof
  the objects landed. Deleting the only copy of a backup is unrecoverable (proof 3).

Cleanup also matched only `*.tar.zst` and `*.tar.gz`, so a partial `*.tar` from an
interrupted backup was never removed by anything (proof 4).

## Confirm on the box

Run these before assuming the analysis above; they separate "the backup hook" from
"something else is eating the disk". SSM session to the primary as root.

```bash
# 1. Where the space actually is. If /home/admin_backups or /home/backup hold tens of
#    GB, this was the backup hook. If they are near-empty, stop and look elsewhere.
df -h /
du -sh /home/admin_backups /home/backup /var/log /home/*/  2>/dev/null | sort -rh | head -20

# 2. Which defect fired. A "cleaned local system backup dirs" line with the directory
#    still present on disk is defect 2; an ERROR or a run that stops mid-way is defect 1.
tail -100 /var/log/da-backup-s3.log
ls -la /home/backup/                 # directories older than today = never cleaned up
ls -la /home/admin_backups/

# 3. Did the outage coincide with the backup window? server = Wed 05:30 by default.
grep -i backup /usr/local/directadmin/data/admin/backup_crons.list 2>/dev/null
journalctl --since '2026-09-06 00:00' -p err --no-pager | head -50
grep -iE "no space|disk full|ENOSPC" /var/log/messages /var/log/mysqld.log \
  /var/log/exim/mainlog 2>/dev/null | head -20

# 4. Confirm S3 has the backups the local disk is still holding. If it does, the local
#    copies are pure waste and safe to delete; if it does not, upload before deleting.
rclone size "s3backup:wbat-tellerstech-directadmin-backups-708113892725/$(hostname -s)/"
rclone lsf "s3backup:wbat-tellerstech-directadmin-backups-708113892725/$(hostname -s)/"

# 5. Is the hook on this box even the repo's version? This has bitten twice before.
cd /root/wbat-terraform && git pull
./scripts/directadmin/install_da_vhost_listen.sh --verify
```

Step 5 is not a formality. This repo has no deploy pipeline, the backup hooks were
installed by hand from a README table, and the hook's own troubleshooting table already
lists "Upload works but local disk stays full → old stub hook (no cleanup)". A host still
running an older hook is a real possibility, and `--verify` now covers the backup hooks
so the answer is definite.

## Recover the space now

Deploy the fixed hook first, then let it do the work — it uploads everything still on
disk, verifies it in S3, and only then deletes. That is safer than `rm -rf` by hand.

```bash
cd /root/wbat-terraform && git pull
sudo ./scripts/directadmin/install_da_vhost_listen.sh --install

# Uploads leftovers, verifies them in S3, deletes only what was verified.
/usr/local/directadmin/scripts/custom/all_backups_post.sh; echo "rc=$?"

tail -40 /var/log/da-backup-s3.log
df -h /
/usr/local/sbin/da-disk-guard.sh --report      # top consumers, no alert
```

If the volume is so full that rclone cannot run, free a little first — truncating the
unrotated log is the safest thing to remove, since S3 holds the backups:

```bash
ls -la /var/log/da-backup-s3.log
: > /var/log/da-backup-s3.log
```

Then re-run the hook. If it still cannot make progress, delete the **oldest** system
backup directory that step 4 above confirmed is already in S3 — never the newest, which
may be the only copy.

## What changed as a result

| Change | Defect it closes |
|--------|------------------|
| `all_backups_post.sh` no longer uses `set -e`; each fallible command captures its own status | 1 — one upload error no longer skips all cleanup |
| Each cleanup is gated on its own verified upload, independent of the other unit | 1 — a system failure no longer keeps admin archives on disk |
| Upload and cleanup share one resolved path and one frozen date | 2 — cleanup can no longer target a directory the upload never sent |
| `rclone check` must confirm the objects in S3 before any local delete | data loss on an unverified upload |
| Cleanup deletes exactly the enumerated, verified file list | data loss for files arriving mid-upload; stray `*.tar` leftovers |
| `flock` around the whole run | concurrent admin + system hooks racing each other |
| Mails `HEALTH_ALERT_TO` when a run ends with backups still on disk, and when a clean run leaves the disk above 90% | 3 — failures are no longer silent |
| [`da_disk_guard.sh`](../../scripts/directadmin/da_disk_guard.sh) + `cron.d-da-disk-guard`, hourly, space **and** inodes | the missing disk alarm |
| [`logrotate.d-da-ops`](../../scripts/directadmin/logrotate.d-da-ops) | unrotated logs on the volume they protect |
| Backup hooks, disk guard, cron, and logrotate added to `install_da_vhost_listen.sh --verify` | a merged fix that never reaches the host |
| [`prove_backup_cleanup.sh`](../../scripts/directadmin/prove_backup_cleanup.sh) | all six behaviours become regression tests |

## Not done here

- **A real CloudWatch disk alarm.** `da_disk_guard.sh` depends on the host being healthy
  enough to run cron and submit mail, which is exactly what a full disk threatens. A
  proper alarm needs the CloudWatch agent installed and publishing `disk_used_percent`,
  plus an `aws_cloudwatch_metric_alarm` beside the billing alarms. Worth doing; it is an
  instance-configuration change on a pet server, not a Terraform-only one.
- **Right-sizing the volume or the local retention.** 200 GB is fine if cleanup works.
  If DirectAdmin's own retention is keeping more than one backup set locally, trimming it
  in the DA UI removes the dependence on the hook running perfectly every time.
- **Restore rehearsal.** These defects mean some backups may never have reached S3. Step 4
  above lists what is actually in the bucket; a restore has not been tested from it.
- **Splitting the S3 prefix.** Admin and system backups both upload into
  `<host>/<date>/`, which works only because their filenames differ. Separate prefixes
  would be tidier but change the restore procedure.
