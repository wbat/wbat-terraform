# 2026-09-06 primary outage — memory exhaustion, not the full disk

**Incident:** `server.wbat.net` (primary, `i-0118b8ede80b52ef7`) became unresponsive at
about 03:50 EDT on Sunday 2026-09-06 and stayed down until a reboot at 09:13 EDT
(13:13 UTC). The root volume was noticed at 99% used.

**Short answer:** the 99% disk did **not** cause this outage. The host ran out of
*memory*. A nightly cron job at 03:45 loads a 472 MB SQLite table into a 3.8 GB instance;
on this run committed memory reached 9.6 GB, swap went from 17.6% to 85.9% inside one
ten-minute interval, and the box thrashed until it was rebooted five hours later.

The disk is a real problem, just a different one, and the investigation turned up two
worse ones: **no backup has reached S3 since 2026-07-02**, and the weekly system backup
**stopped including databases** on 2026-09-05. See
[What actually needs fixing](#what-actually-needs-fixing).

## Do it in this order

The order matters, because the obvious first move is the one that breaks the host.
`directadmin admin-backup` with no `--user` backs up every account, and on 2026-07-02 that
produced roughly 45 GB of archives — `user.wbatnet.teller.tar.zst` alone was 43.4 GB.
There is **3.8 GB free**. Running a full backup to buy peace of mind would fill the root
volume within a minute and cause the ENOSPC outage this document spends its first half
establishing did not happen. It is also exactly how the 2026-06-28 failure went.

So: cap the memory first because it is free and tonight is coming, then buy disk headroom,
then touch DirectAdmin.

| # | Action | Disk cost | Why here |
|---|--------|-----------|----------|
| 1 | [Cap the nightly cron job](#3-memory-headroom-on-the-primary--and-why-more-swap-is-the-wrong-lever) | none | The job runs at 03:45 daily and has come close every night for a week. Costs nothing and needs no disk. |
| 2 | [Upload the old `/backup` weeks, verify, then delete](#recovering-space-safely) | **frees ~52 GB** | `rclone` streams to S3 without staging locally, so this works at 99%. Takes the volume to ~74% and gets the newest database dump off-host in the same pass. |
| 3 | Deploy the fixed tooling: `install_da_vhost_listen.sh --install` | negligible | Nothing else uploads or cleans up, and the installed hook is hand-edited. Must be in place before a backup succeeds. |
| 4 | [Smoke-test DirectAdmin with one small account](#1-prove-the-backup-engine-works-without-filling-the-disk-cli) | kilobytes | Proves engine → hook → S3 → cleanup end to end for almost no space. |
| 5 | [Diagnose `Not implemented`](#2-find-out-what-not-implemented-refers-to-cli) | none | Read-only. |
| 6 | [Recreate the schedule](#3-recreate-the-backup-schedule--this-one-needs-the-panel) (panel) | — | Only once 2 and 4 have passed. |
| 7 | A full all-users backup | **~45 GB** | Needs step 2 to have completed first. See the note there about peak local usage. |

## How this was established

Evidence was collected read-only over SSM from both hosts and is reproducible with
[`collect-outage-evidence.sh`](collect-outage-evidence.sh). Throughout this document,
quoted command output is **observed**; anything that is a reading of that output rather
than the output itself is marked **inferred**. The distinction matters here, because the
first version of this document reasoned from the repository alone and reached the wrong
conclusion.

## What the disk hypothesis predicted, and what was found

The original hypothesis was that `/` hit 100%, MySQL and Exim failed writes, and the
backup hook was why the volume filled. Three predictions, none of which survived.

**The volume never reached 100%, and inodes were never a factor.**

```text
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  200G  197G  3.8G  99% /
Filesystem      Inodes  IUsed   IFree IUse% Mounted on
/dev/nvme0n1p2 8786256 866379 7919877   10% /
```

3.8 GB free is not much, but it is not zero, and nothing on this host needs 3.8 GB of
headroom to keep serving.

**No service logged a single out-of-space error during the incident.** Greps for
`no space left on device`, `ENOSPC`, and `disk full` across `/var/log/messages*`,
`maillog*`, `/var/log/exim/mainlog*`, `paniclog`, `/var/log/directadmin/*.log`, and the
MySQL error log for Sep 5–6 returned **zero lines**. The only such errors anywhere on the
box are from 2026-06-28, a separate episode when DirectAdmin still staged backups in
`/tmp`, and from 2023 on a different instance.

**The directories the backup hook manages are empty.**

```text
0	/home/admin_backups
0	/home/backup
```

Both contain nothing but `.` and `..`. They are 0% of the used space, so the hook's
cleanup cannot be what filled this volume.

Two caveats, stated because they bound the conclusion rather than weaken it. There is no
disk-usage *time series* for the incident: `sar -F` is not enabled (`Requested activities
not available in file /var/log/sa/sa06`) and no CloudWatch disk metric is published.
"The disk was at 99%, not 100%, during the outage" is therefore **inferred** from the
state at capture time plus the fact that nothing was reclaimed in between — no
deleted-but-open files (`deleted-open bytes: 0`), `/backup` mtimes unchanged since Sep 5,
and no cleanup commands in root's shell history. The absence of ENOSPC across seven log
sources is the stronger evidence, and it is direct.

## What actually happened

**The trigger is a cron job at 03:45 EDT.**

```text
45 3 * * * cd /home/tellerstec/public_html/wp-content/plugins/tellerstech-landing && \
  RUN_ALL_HEALTHCHECK_URL=... python3 oncallbrief-pipeline/run_all.py \
  >> /home/tellerstec/logs/oncallbrief.log 2>&1
```

Its log stops mid-run and never resumes:

```text
03:46:40 INFO Dedupe: loading raw items (since=2026-09-06T07:31:34)...
03:46:47 INFO Dedupe: checking for stragglers from earlier runs...
03:46:47 INFO Dedupe: loading raw items (since=all)...
```

That `since=all` is an unbounded load of a 472 MB SQLite database
(`oncallbrief-pipeline/data/oncallbrief.db`). It is the last line the file ever received.
On Sep 4 and Sep 5 the same job ran on past this point and finished around 03:54.

**Memory collapses in the next `sar` interval.** From `/var/log/sa/sa06`, the 03:50:01
sample covering 03:40–03:50:

```text
             kbmemfree   kbavail  kbmemused  %memused   kbcached   kbcommit  %commit
03:40:00        128672   2196196    1127636     28.50    1870648    4233600    51.94
03:50:01        148532    301308    3232248     81.70     374676    9609092   117.89

             kbswpfree kbswpused  %swpused  pswpin/s  pswpout/s  pgscank/s  pgsteal/s
03:40:00       3457072    737228     17.58     12.45       0.04      97.78     210.25
03:50:01        591836   3602464     85.89     91.00    1271.62    4319.10    4382.28
```

Committed memory 9.6 GB against 3.8 GB of RAM, available memory down to 301 MB, page
cache collapsed from 1.87 GB to 374 MB, and page-out rate up by a factor of thirty
thousand. Disk `tps` went 24 → 669 in the same interval — swap I/O, not backups.

**Then the host stops being able to do work.** php-fpm children start dying:

```text
Sep  6 03:52:24 server php-fpm[1280161]: [WARNING] [pool tellerstec] child 3339517 exited on signal 9 (SIGKILL) after 61.898165 seconds from start
Sep  6 03:53:50 server php-fpm[1280161]: [WARNING] [pool teller] child 3339683 exited on signal 9 (SIGKILL) after 70.633110 seconds from start
Sep  6 03:59:51 server systemd[1]: user@1012.service: start operation timed out. Terminating.
Sep  6 04:03:37 server systemd[1]: Starting Automatically configure NetworkManager in cloud...
```

That last line is the final entry in `/var/log/messages` before the reboot. Hourly line
counts show the host going quiet: **2897** lines in the 03:00 hour, **1** in the 04:00
hour, then nothing until 09:00.

**A caveat on attribution.** A grep for `out of memory`, `oom-kill`, `oom_reaper`,
`Killed process`, and `invoked oom` across the current and rotated `messages` returned
**zero lines**, and `/var/log/journal` does not exist, so journald was volatile and no
pre-reboot kernel log survived. "The kernel OOM killer took these processes" is therefore
**inferred**. php-fpm also SIGKILLs its own children on `request_terminate_timeout`, so
the signal alone does not identify the sender. What is directly observed is severe memory
exhaustion and swap thrash; the specific killer is not.

**CloudWatch corroborates from outside the box** (UTC; the host is EDT, UTC-4):

| Time (UTC) | Time (EDT) | Observation |
|---|---|---|
| 07:30 | 03:30 | CPU 6.91% — normal overnight idle |
| 07:45 | 03:45 | CPU 33.26% — the cron job starts |
| 08:00 | 04:00 | CPU 88.22%, and it stays 92–100% until 13:00 |
| 08:00 hr | 04:00 hr | `StatusCheckFailed_Instance` starts failing; `StatusCheckFailed_System` stays 0 throughout |
| 13:13 | 09:13 | Reboot. `LaunchTime 2026-09-06T13:13:13+00:00`, kernel boot `Sep 6 09:13:26 EDT`. CPU back to 7.37% at 13:15 |

Five hours of pegged CPU with a healthy hypervisor is what swap thrash looks like from
the outside. `CpuCredits` is `unlimited` and `CPUSurplusCreditBalance` was 0.0 throughout,
so CPU credit exhaustion is ruled out.

**This has been close before.** Peak swap in the 03:50 sample, per day, from `sa30`–`sa06`:

```text
Aug 30  64.3%     Sep 02  80.5%     Sep 04  84.0%     Sep 06  85.9%
Aug 31  80.9%     Sep 03  96.7%     Sep 05  80.7%
Sep 01  80.8%
```

Every night, same interval, same job. Sep 3 peaked *higher* than the night it died and
survived. Whatever tipped Sep 6 over is a matter of degree, and the reading that this was
"the same event with a worse roll of the dice" is **inferred** — but the pattern is not.

## The disk is still a real problem

197 GB of a 200 GB volume is in use, and none of it is where the backup hook was looking.

```text
203834168	/            (KB)
116112576	/home        110.7 GiB — legitimate customer data
 62200704	/backup       59.3 GiB — see below
 13088876	/usr
  7954936	/var
```

`/backup` — at the filesystem root, **not** `/home/backup` — holds nine weekly system
backups that nothing has ever pruned:

```text
6.2G  /backup/07-04-26      6.6G  /backup/08-08-26      7.4G  /backup/08-29-26
6.2G  /backup/07-11-26      6.7G  /backup/08-15-26       60K  /backup/09-05-26
6.4G  /backup/07-18-26      7.4G  /backup/08-22-26
6.4G  /backup/07-25-26      6.5G  /backup/08-01-26
```

Written weekly by root's crontab, `0 5 * * 6 /usr/local/directadmin/shared/sysbk.sh -q`.
**None of them is in S3** (see below), so they are the only copy and must be uploaded
before they are deleted.

The secondary is a useful control: same tooling, 32% used, no `/backup` directory at all.

## What actually needs fixing

### 1. Backups have produced nothing for 66 days — highest severity

This is worse than the outage. The DirectAdmin admin backup task itself fails
immediately:

```text
Sep  5 05:00:51 server dataskq[2747705]: running backup task data=map[... local_path:[/home/admin_backups]
  ... type:[admin] ... who:[all]] error=error code 1: Not implemented
Sep  5 05:00:51 server dataskq[2747705]: finished task duration=66.334153ms task=action=backup&id=1
```

66 milliseconds, no files produced. A *post*-backup hook cannot fire when the backup
never runs, so **no hook fix restores uploads until this is repaired**. Corroborating:
`/home/admin_backups` is empty with mtime 2026-07-02, `/var/log/da-backup-s3.log` has not
been written since 2026-07-02 05:52, and S3 confirms it:

```text
PRE 2026-06-28/   PRE 2026-06-29/   PRE 2026-06-30/   PRE 2026-07-02/
2026-07-02 09:46:18   43.4 GiB server/2026-07-02/user.wbatnet.teller.tar.zst
```

Nothing under `server/` is newer than 2026-07-02. Only one dated `Not implemented` line
was captured, so "it has failed every day since Jul 2" is **inferred** from the gap;
that it is failing *now* is observed. `error code 1: Not implemented` is a DirectAdmin
message, not a shell error — start with the DA version and the backup task's transport
setting.

### 2. The weekly system backup silently stopped backing up databases

The command in root's crontab changed between Aug 29 and Sep 5:

```text
Aug 29 05:00:02 CROND[3062133]: (root) CMD (/usr/local/sysbk/sysbk -q)
Aug 29 05:22:13 CROND[3061963]: (root) CMDEND (/usr/local/sysbk/sysbk -q)
Sep  5 05:00:02 CROND[2747153]: (root) CMD (/usr/local/directadmin/shared/sysbk.sh -q)
Sep  5 05:00:02 CROND[2747032]: (root) CMDEND (/usr/local/directadmin/shared/sysbk.sh -q)
```

Aug 29 took 22 minutes and produced 7.4 GB including a `mysql/` tree. Sep 5 finished
within the same second and produced 55,051 bytes:

```text
Archiving:
  /etc/nginx
  /etc/httpd
  /var/named
  /etc/named.conf
  -> //backup/09-05-26/sysbk-09-05-26.tar.zst .... Done

System backup has been completed
```

Config only. No databases. It reports success and exits clean, and a 55 KB file is easy
to misread as a backup truncated by a full disk. Who changed the crontab, and when, is
**not established** — there is no audit record and nothing in root's shell history.

### 3. Memory headroom on the primary — and why more swap is the wrong lever

The box is a `t3a.medium`: 2 vCPU, 3.8 GB RAM, plus a 4 GB `/swapfile`.

**The swap that was added earlier is why this presented as a five-hour outage instead of
a failed cron job.** That is not an argument against having swap, but it is an argument
against treating it as the fix. Swap raises the ceiling; it does nothing about demand,
and the demand here is unbounded. `%commit` reached **117.89%** — the kernel had promised
9.6 GB against 7.8 GB of RAM and swap combined — so the ceiling was already gone. What
swap bought was somewhere for the kernel to page to, which is what let a doomed process
keep the host busy for five hours instead of dying in seconds. A box that is alive and
doing no work is worse to operate than one that killed a cron job, because nothing can
run on it, including whatever would have told you.

Two facts say the current 4 GB is already spent: swap peaked at 80–97% on **every** night
of the preceding week, and the `since=all` load appears in all 90 logged runs, against a
database that grows. Another 4 GB buys a few more nights of the same graph.

In order of leverage:

1. **Bound the query.** `Dedupe: loading raw items (since=all)` reads a full table out of
   a 472 MB SQLite file into Python objects, which inflates several times over in memory.
   Chunking it, or doing the dedupe in SQL, is the actual defect. It lives in
   `/home/tellerstec/public_html/wp-content/plugins/tellerstech-landing/oncallbrief-pipeline`,
   not in this repository.
2. **Cap the job so it dies alone.** This is the availability fix and it is independent
   of (1) — it converts "host unreachable for five hours" into "one cron job failed".
   Edit `crontab -u tellerstec -e` and wrap the command:

   ```bash
   45 3 * * * systemd-run --scope --quiet -p MemoryMax=1200M -p MemorySwapMax=0 \
     bash -lc 'cd /home/tellerstec/public_html/wp-content/plugins/tellerstech-landing && \
     RUN_ALL_HEALTHCHECK_URL=<keep the value already in the crontab> \
     python3 oncallbrief-pipeline/run_all.py' >> /home/tellerstec/logs/oncallbrief.log 2>&1
   ```

   `MemorySwapMax=0` is the important half: without it the job is capped on RAM and still
   free to thrash swap. The healthcheck ping doubles as the alert — a killed run stops
   pinging, so it shows up as a missed check rather than needing new monitoring. Verify
   the cap took effect by watching one run with
   `systemd-cgtop` or checking for `memory.max` under the scope's cgroup.
3. **Alert on the trend.** [`da_disk_guard.sh`](../../scripts/directadmin/da_disk_guard.sh)
   now reads the day's peak `%swpused` out of `sar` as well as the current values, which
   is the check that would have flagged this a week early. Defaults warn at 60% swap and
   95% commit.
4. **Resize to a `t3a.large`** (8 GB). Real money, and it raises the ceiling without
   removing the unbounded query underneath it — worth doing only if (1) turns out to be
   impractical.

### 4. The disk — not the cause, but a prerequisite for fixing the causes

The disk did not take the server down, which made it tempting to file at the bottom of the
list. That is wrong for a practical reason rather than a severity one: 3.8 GB of headroom
is not enough to take a backup, so every fix in sections 1 and 2 is blocked behind it.

Roughly 52 GB is recoverable by uploading the eight older `/backup` weeks to S3 and then
deleting them — **in that order**, see
[Recovering space safely](#recovering-space-safely). That pass also lifts the newest
database dump off the host, which is the other reason to do it early.

## Backup hook defects — real, but not the cause

The hook was rewritten in this change. The defects below are genuine and are covered by
[`prove_backup_cleanup.sh`](../../scripts/directadmin/prove_backup_cleanup.sh), which runs
the real hook against a stubbed rclone. What changed is their status: they are why
cleanup would have failed, not why this host went down.

**Defect 3 is the one that actually fired here.** The installed hook hardcodes
`SYSTEM_ROOT="/home/backup"`, a directory that exists and is empty, while DirectAdmin
writes to `/backup`. So every run cleaned nothing and logged:

```text
2026-07-02T05:52:17-04:00 cleaned local system backup dirs under /home/backup
```

That line reads exactly like the date-mismatch defect and has a completely different
cause — which is why fixing only the date handling would not have freed a single byte.
The installed file matches no committed version (sha256 `5b334e6b…`, mtime 2026-06-30
16:48), so it was hand-edited on the box; the secondary runs the committed `70ee281`.

| # | Defect | Status on the primary |
|---|--------|----------------------|
| 1 | `set -e` aborted the run before cleanup on any rclone error | Did **not** fire — no ERROR or non-zero rclone lines in the hook log |
| 2 | Cleanup recomputed the date instead of reusing the resolved directory | Cannot have fired — the root it looked at was empty |
| 3 | `SYSTEM_ROOT` hardcoded to a path DirectAdmin does not use | **Fired.** Logged success over a no-op for two months |
| 4 | No alerting, no disk check, no log rotation | Fired — nothing reported any of the above |

Two data-loss defects were found in the same code and fixed in the same pass: files
arriving mid-upload were deleted without ever being uploaded, and deletion was never
verified against S3.

**Fixing defect 3 created a new hazard, which is also fixed here.** Point a working
`find -mtime +7 -exec rm -rf` at the root that really holds the backups and its first run
deletes eight weekly archives — 52 GB for which no S3 object exists. The sweep now
verifies each directory against the prefix it would have been uploaded to, keeps whatever
it cannot confirm, and mails about it. Proof 8 covers it.

## Recovering space safely

This is step 2 of [the order above](#do-it-in-this-order), and it does double duty: it
frees the headroom every DirectAdmin fix needs, and it is what gets the databases off the
host. **The newest database backup that exists anywhere is `/backup/08-29-26/mysql`, on
the same disk as the database it protects** — admin backups carry the databases and have
failed since July, and the Sep 5 system backup dropped them, so nothing off-host is newer
than 2026-07-02. If you only have time for one command today, make it the `08-29-26` one.

Uploading is safe to do at 99% full: `rclone` streams from local files straight to S3 and
stages nothing on disk. It is I/O heavy but not space heavy.

**Do not delete anything under `/backup` before it is in S3.** Those nine directories are
the only copy. Confirm for yourself first:

```bash
aws s3 ls s3://wbat-tellerstech-directadmin-backups-708113892725/server/
```

If nothing newer than `2026-07-02/` appears, upload before deleting. Note the ordering:
`08-29-26` goes first because it holds the only recent database dump, and a lexicographic
glob would otherwise leave it until last.

Each week that verifies records its own path. The deletion step then reads that file rather
than re-globbing, so a directory whose upload or checksum failed cannot be removed by the
next command even if you paste both blocks in one go.

```bash
BUCKET=s3backup:wbat-tellerstech-directadmin-backups-708113892725/server
VERIFIED_LIST=/root/backup-weeks-verified.txt
: >"$VERIFIED_LIST"

upload_week() {
  local d="$1" stamp iso
  stamp="$(basename "$d")"                    # MM-DD-YY
  iso="20${stamp:6:2}-${stamp:0:2}-${stamp:3:2}"
  if rclone copy "$d" "${BUCKET}/${iso}/" --s3-no-check-bucket --checksum --transfers 4 &&
     rclone check "$d" "${BUCKET}/${iso}/" --s3-no-check-bucket --checksum --one-way; then
    echo "VERIFIED $d"
    printf '%s\n' "$d" >>"$VERIFIED_LIST"
  else
    echo "FAILED   $d -- keeping the local copy, this one is still the only one"
  fi
}

upload_week /backup/08-29-26                  # newest databases -- do this one first
for d in /backup/07-* /backup/08-0* /backup/08-1* /backup/08-22-26; do
  upload_week "$d"
done
```

Now delete, keeping `08-29-26` on disk as the local copy of the most recent week. Read the
count first: if it is lower than you expect, something above printed `FAILED` and that week
still exists in one place only.

```bash
grep -vx /backup/08-29-26 "$VERIFIED_LIST" >/root/backup-weeks-to-delete.txt
wc -l </root/backup-weeks-to-delete.txt        # expect 8

while IFS= read -r d; do
  echo "removing $d"
  rm -rf -- "$d"
done </root/backup-weeks-to-delete.txt
df -h /                                        # expect ~74% used, ~52 GB reclaimed
```

That is enough headroom for the DirectAdmin steps. Then deploy the fixed tooling so this
does not recur:

```bash
cd /root/wbat-terraform && git pull
sudo ./scripts/directadmin/install_da_vhost_listen.sh --install
./scripts/directadmin/install_da_vhost_listen.sh --verify
/usr/local/sbin/da-disk-guard.sh --report
```

`--verify` matters: the primary's hook was hand-edited and matched no commit, so a merged
fix would not otherwise have been running.

## DirectAdmin remediation — what to run, and what needs the panel

**Prerequisite: [free the disk first](#recovering-space-safely).** Everything below either
writes archives to the root volume or is pointless without somewhere to put them, and the
volume has 3.8 GB free.

### 1. Prove the backup engine works without filling the disk (CLI)

DirectAdmin can run an admin backup in the foreground, bypassing the task queue that the
scheduled job goes through. Scope it to **one small account**, because a full run writes
every account's archive to local disk before the post-backup hook gets a chance to upload
anything:

```bash
/usr/local/directadmin/directadmin admin-backup --destination=/home/admin_backups --user=test2
```

`test2`, `brian2` and `aubrey` were all under 2 MB in the last successful backup, so any of
them proves the whole chain — engine writes, hook fires, objects land in S3, local copy is
removed — for kilobytes. Check all four stages, not just the command's exit status:

```bash
ls -la /home/admin_backups/                    # did the engine produce a file?
tail -20 /var/log/da-backup-s3.log             # did the hook fire?
aws s3 ls s3://wbat-tellerstech-directadmin-backups-708113892725/server/ | tail -3
ls -la /home/admin_backups/                    # and did it clean up after itself?
```

This is also the cleanest diagnostic split available:

- **It succeeds** → the backup engine is fine and the fault is in the stored job or the
  task queue. Continue at step 2.
- **It fails the same way** → the fault is in DirectAdmin itself, and step 2's debug
  output is what to send to DA support.

**On the eventual full run.** `all_backups_post.sh` is DirectAdmin's *all backups*
hook — it fires once, after every account has been archived, so peak local usage is the
sum of all archives at once (~45 GB, dominated by `teller` at 43.4 GB). Step 2 of the
order above leaves roughly 52 GB free, which covers it but not comfortably. Two ways to
avoid needing that headroom at all, neither implemented here: back up a few accounts at a
time with repeated `--user=` runs, letting the hook clear each batch; or move the upload to
DirectAdmin's per-user `user_backup_post.sh` hook so each archive is uploaded and deleted
as it is produced, which would cap peak usage at the largest single account instead of the
sum. The second is the better answer if `teller` keeps growing.

### 2. Find out what `Not implemented` refers to (CLI)

Re-queue the failing job by hand and run the task queue at debug level. `d2000` is the
most verbose of the documented levels (`d80`, `d400`, `d800`, `d2000`):

```bash
echo 'action=backup&id=1' >> /usr/local/directadmin/data/task.queue.da
/usr/local/directadmin/dataskq d2000
```

The 66 ms failure means the task was accepted and rejected internally, so the debug
output should name the unsupported part. Also worth reading:

```bash
tail -100 /var/log/directadmin/errortaskq.log
cat /usr/local/directadmin/data/admin/backup_crons.list     # the stored job, id=1
grep -nE 'taskqueue|backup' /usr/local/directadmin/conf/directadmin.conf
```

Two known causes of task-queue failures worth ruling out while you are in there: a
`taskqueueda=` override in `directadmin.conf` with a stray carriage return (DA 1.650+
stopped tolerating it), and a `directadmin.conf` edited on Windows so every value has
`\r` appended.

### 3. Recreate the backup schedule — this one needs the panel

There is no documented CLI command to *create or edit a scheduled* backup. The task queue
accepts `action=backup` for a one-off run, and `admin-backup` runs one immediately, but
the cron entry itself is written by the GUI wizard. So if step 2 shows the stored job is
malformed, recreate it at **Admin Level → Admin Backup/Transfer → Schedule**:

- **Who:** All Users
- **When:** Cron Schedule, minute `0`, hour `5`, day of month `*`, month `*`, day of week `*`
- **Where:** Local, path `/home/admin_backups` — must match `local_path` in the hook
- **What:** All data

Then delete the old job so both are not queued. The scriptable equivalent, if you would
rather not use the browser, is `CMD_API_ADMIN_BACKUP` with `action=create`; DirectAdmin
does not document its full parameter list and suggests running DA in debug mode to
capture what the GUI sends, so the panel is genuinely the lower-risk path here.

After it runs, confirm the whole chain rather than just the panel's success message:

```bash
ls -la /home/admin_backups/                    # did files appear?
tail -40 /var/log/da-backup-s3.log             # did the hook fire and upload?
aws s3 ls s3://wbat-tellerstech-directadmin-backups-708113892725/server/ | tail -5
```

### 4. Restore databases to the weekly system backup (CLI)

The Sep 5 run archived four config paths and no databases. Compare the two scripts and
put the databases back:

```bash
crontab -l | grep sysbk
ls -la /usr/local/sysbk/sysbk /usr/local/directadmin/shared/sysbk.sh
diff <(cat /usr/local/sysbk/sysbk 2>/dev/null) /usr/local/directadmin/shared/sysbk.sh
cat /var/log/directadmin/sysbk.status.log
```

If the old script is still present and worked, reverting root's crontab to it is the
smallest change. Verify by size, not by exit status — a correct run is gigabytes and
takes about twenty minutes, and the broken one exits clean in under a second:

```bash
/usr/local/directadmin/shared/sysbk.sh -q; echo "rc=$?"
du -sh /backup/"$(date +%m-%d-%y)"            # config-only is ~55 KB; with databases, GB
ls /backup/"$(date +%m-%d-%y)"/               # expect a mysql/ directory
```

Note that step 3 makes this partly redundant: admin backups include databases, so once
they work again the system backup matters mainly for server configuration. Both are worth
having, but fix the admin backup first.

## Re-running the evidence capture

[`collect-outage-evidence.sh`](collect-outage-evidence.sh) collects everything above
read-only over SSM and prints a verdict:

```bash
./aws/docs/collect-outage-evidence.sh --profile wbat
./aws/docs/collect-outage-evidence.sh --profile wbat --host secondary
./aws/docs/collect-outage-evidence.sh --analyze /tmp/capture   # offline, no credentials
```

It needs `ssm:SendCommand` and `ssm:GetCommandInvocation`. It exits 0 when the disk
hypothesis holds, 1 when the evidence contradicts it, and 2 when the capture cannot
settle it. On this incident it should exit 1 for the primary.

Two things it does **not** cover, both of which were answered by hand and are worth
folding in: the `sar` memory series, and whether the DirectAdmin backup task is producing
files at all.

## Still open

- **The kernel-side cause of the process kills** is unconfirmed. `dmesg` was never
  captured and journald is volatile here; enabling a persistent journal
  (`mkdir -p /var/log/journal && systemctl restart systemd-journald`) would make the next
  occurrence answerable.
- **No CloudWatch disk or memory alarm exists.** The only alarms in this account are the
  two billing alarms in [`billing-alarms.tf`](../global/cloudwatch/billing-alarms.tf).
  [`da_disk_guard.sh`](../../scripts/directadmin/da_disk_guard.sh) added here covers disk,
  inodes, and memory, but it is hourly cron on the host — exactly what a thrashing box
  cannot run. It reads `sar` history specifically so it can report a spike it slept
  through, but that is after the fact. An alarm that can page during the event needs the
  CloudWatch agent publishing `disk_used_percent` and `mem_used_percent`, plus
  `aws_cloudwatch_metric_alarm` resources beside the billing alarms.
- **`StatusCheckFailed_Instance` is already published and unalarmed.** It went to 1 for
  four and a half hours during this outage with no notification. That is a metric EC2
  emits for free, needs no agent, and would have caught this — the cheapest available
  improvement, and it belongs in Terraform.
- **Restore has never been rehearsed**, and the bucket's newest primary backup is from
  2026-07-02. Whatever is restorable today is over two months stale.
- **`/usr/local/sbin/migrate-backups-to-s3.sh` and `verify-backups-s3.sh`** exist on the
  host, are not in this repository, and were not examined.
