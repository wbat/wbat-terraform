# 2026-09-06 primary outage — memory exhaustion, not the full disk

**Incident:** `server.wbat.net` (primary, `i-0118b8ede80b52ef7`) became unresponsive at
about 03:50 EDT on Sunday 2026-09-06 and stayed down until a reboot at 09:13 EDT
(13:13 UTC). The root volume was noticed at 99% used.

**Short answer:** the 99% disk did **not** cause this outage. The host ran out of
*memory*. A nightly cron job at 03:45 does `SELECT * FROM raw_items` against a 2.9 GB MySQL
table and `fetchall()`s it into a 3.8 GB instance; on this run committed memory reached
9.6 GB, swap went from 17.6% to 85.9% inside one ten-minute interval, and the box thrashed
until it was rebooted five hours later.

The disk is a real problem, just a different one, and the investigation turned up two
worse ones: **no backup has reached S3 since 2026-07-02**, and the weekly system backup
**stopped including databases** on 2026-09-05. See
[What actually needs fixing](#what-actually-needs-fixing).

**Where this stands, for a reader arriving after the fact.** The memory fix is deployed and
the query is bounded. The system backup is producing databases again. Eleven of the
thirteen accounts got a backup on 2026-09-07, the first since July, and the other two do
not fit on this volume at all. Chasing that surfaced a third problem worse than either
of the two above: an archive can be checksum-verified into S3 and still be unreadable, and
[reading the whole bucket
back](#is-what-is-already-in-s3-readable-a-read-back-of-every-archive-2026-09-08) found 22
that are. Only one of the 22 is the newest object in the bucket for its account, and that
one is the `tellerstec` fragment already known about and already renamed. What is still
outstanding is in
[the order below](#do-it-in-this-order) and in [Still open](#still-open); nothing from the
batching work is on the host yet.

## Do it in this order

The order matters, because the obvious first move is the one that breaks the host.
`directadmin admin-backup` with no `--user` backs up every account, and on 2026-07-02 that
produced **66.055 GiB across 13 objects** — `user.wbatnet.teller.tar.zst` alone was 43.4
GiB. There was **3.8 GB free** when this order was written. Running a full backup to buy
peace of mind would fill the root volume within a minute and cause the ENOSPC outage this
document spends its first half establishing did not happen. It is also exactly how the
2026-06-28 failure went.

(An earlier revision put that first figure at "roughly 45 GB", which is `teller`'s archive
mistaken for the whole run. The correct total is the one the bucket reports, and it is the
number the staging arithmetic further down depends on.)

So: cap the memory first because it is free and tonight is coming, then buy disk headroom,
then touch DirectAdmin.

Steps 1 to 4 have since been done, and the disk is now at 71% with 59.8 GiB free. That
did **not** make step 7 a full backup again — DirectAdmin holds an account's assembled
parts and the archive it tars out of them on disk at the same time, so a full run needs
around twice the 66.055 GiB of finished archives above. It has not fitted on this volume
since July and it does not fit now. Step 7 is therefore the per-account batch run, and
step 6 exists to stop DirectAdmin's own schedule racing it.

| # | Action | Disk cost | Status | Why here |
|---|--------|-----------|--------|----------|
| 1 | [Cap the nightly cron job](#3-memory-headroom-on-the-primary--and-why-more-swap-is-the-wrong-lever) | none | done 2026-09-07 | The job runs at 03:45 daily and has come close every night for a week. Costs nothing and needs no disk. |
| 2 | [Upload the old `/backup` weeks, verify, then delete](#recovering-space-safely) | **frees ~52 GB** | done 2026-09-07 | `rclone` streams to S3 without staging locally, so this works at 99%. Takes the volume to ~74% and gets the newest database dump off-host in the same pass. |
| 3 | [Deploy the fixed tooling](#state-of-the-host-as-of-2026-09-07-2130-edt): merge, then `install_da_vhost_listen.sh --install` and `--verify` | negligible | done for #120's tooling; **re-run after #122 merges** | Nothing else uploads or cleans up, and the installed hook was hand-edited. Also installs `da-backup-batch.sh` and its cron, which is why step 6 has to happen alongside it. |
| 4 | [Smoke-test DirectAdmin with one small account](#1-prove-the-backup-engine-works-without-filling-the-disk-cli) | kilobytes | done 2026-09-07 | Proves engine → hook → S3 → cleanup end to end for almost no space. |
| 5 | [Diagnose `Not implemented`](#2-find-out-what-not-implemented-refers-to-cli) | none | not done, and optional | Read-only, and no longer on the critical path — step 7 does not go through the task queue. |
| 6 | [Delete DirectAdmin's schedule](#3-delete-directadmins-backup-schedule--this-one-needs-the-panel) (panel) | — | **not done** | It still fires at 05:00 every day. Repairing it would restore a full all-users run, which no longer fits. |
| 7 | [Let the per-account batch run take over](#per-account-backups-da_backup_batchsh) | largest single account, not the sum | **not scheduled** | Installed by step 3. Eleven of the thirteen accounts fit; the other two need a disk decision, not a schedule. |

### State of the host, read 2026-09-07 05:02 UTC

Merging the pull request that carries this document changes nothing on the server — this
repository has no deploy pipeline, which is the same gap `--verify` exists to close. As of
that reading, every step above is still outstanding:

| Checked | Found |
|---|---|
| `/etc/oncallbrief.env` | Exists, `0600 root:root`, one `RUN_ALL_HEALTHCHECK_URL` line — **but nothing reads it yet** |
| `oncallbrief.service` / `.timer` | Not installed. Both `run_all.py` entries still in `crontab -u tellerstec`, uncapped, still carrying the leaked URL |
| `stat -fc %T /sys/fs/cgroup` | `cgroup2fs` — `MemorySwapMax` will be enforced |
| Installed backup hook | Still `SYSTEM_ROOT="/home/backup"`, i.e. the pre-fix version. `da_disk_guard.sh` absent |
| `df -h /` | `197G / 3.8G avail / 99%`, inodes 10% |
| `/backup` | Now **60 GB across ten** dated directories — `09-05-26` has appeared since the first capture |
| `crontab -u root` | Still `0 5 * * 6 /usr/local/directadmin/shared/sysbk.sh -q`, the config-only script. Next fires Sat 05:00 |
| `oncallbrief.log` | Last line is still `03:46:47 ... since=all` from Sep 6. The job has not run since |

### Step 1 completed 2026-09-07 05:17 UTC

The units are installed and both `run_all.py` cron entries are commented out. Verified
afterwards, because each of these had a way to fail that looks like success:

| Checked | Result |
|---|---|
| `MemoryMax` / `MemorySwapMax` | `2726297600` / `3565158400` — the corrected 2600M + 3400M |
| `TimeoutStartUSec` | **`infinity`**. `Type=oneshot` disables the start timeout; had it inherited the 90 s default, every 13-minute run would have been killed at 90 seconds |
| `python3` under the unit | `/usr/bin/python3`, 3.9.25 — byte-identical resolution to the old cron `PATH`, and `httpx 0.28.1` imports, matching the `python-httpx/0.28.1` user agent in the check's history |
| `/etc/oncallbrief.env` | Read by the unit, contains a well-formed hc-ping URL, and does **not** contain the leaked `24677487` UUID |
| `crontab -u tellerstec` | No active `run_all` line. The `*/20` `send_siw` entry left alone |
| `systemctl list-timers` | Next run `Mon 2026-09-07 03:45:00 EDT`. `Persistent=true` did not fire a catch-up on enable |

The two commented-out cron lines still contain the leaked URL. Harmless once the old check is
deleted, but they are a loaded gun: uncommenting one restores an uncapped job pointed at a dead
ping URL. Delete the lines rather than leaving them commented.

The Monday 02:45 catch-up is now disabled outright rather than moved to a timer. That is fine
while the previous week's brief exists — it exits in under a second — but nothing runs the
expensive path if a week is ever missed.

### Root cause fixed 2026-09-07 17:23 UTC

The unbounded query is gone and the pipeline completes again. The whole run now peaks at
**667 MB against its 2600 MB cap and uses no swap at all**, where the 03:45 run that morning
was OOM-killed with 2600 MB of RAM and 3400 MB of swap available to it. Full detail, including
what was measured and why the other two proposed remedies were dropped, is in
[What the fix does, and what it measured](#what-the-fix-does-and-what-it-measured).

The change is deployed on the primary but **is not yet committed to
`TellersTechOrg/tellerstech-website`** — that repository is private and outside this
repository's tooling. Until it is committed, the host is ahead of the checkout and a
redeploy from `main` would reintroduce the outage. The originals are backed up on the box at
`/root/oncallbrief-prefix-backup-20260907-130955/`, alongside a pre-run dump of `items`.

The patch itself is deliberately **not** committed here. This repository is public and that
one is not, so the diff is attached to the pull request as a downloadable artifact instead of
being checked in.

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

That `since=all` is an unbounded load of the whole `raw_items` table. It is the last line
the file ever received. On Sep 4 and Sep 5 the same job ran on past this point and finished
around 03:54.

**The store is MySQL, not the SQLite file this document used to name.** Earlier revisions
attributed the load to `oncallbrief-pipeline/data/oncallbrief.db`, 472 MB on disk. That file
is a **stale February artifact**: its newest `pipeline_runs` row is `2026-02-13`, week
`2026-W07`, and its mtime matches. `oncallbrief/store.py` opens MySQL and says so in its
docstring. Measured on the live database `tellerstec_oncallbrief`:

| | |
|---|---|
| `raw_items` | **683,188 rows** (exact), 2,768 MB data + 107 MB index |
| `raw_text` across those rows | **2,650 MB**, averaging 4,067 bytes each |
| Growth | **~3,600 rows and ~16 MB of `raw_text` per day** |
| `items` | **83,479 rows** (exact), 157 MB of `raw_text` + 29 MB of identity columns |

An earlier revision of this table said `items` held 63,265 rows, which does not reconcile
with the 83,479 rows the correctness check below compares — a run that merged 174 raw rows
cannot account for a 20,000-row gap. The 63,265 was an `information_schema.tables.table_rows`
reading, which for InnoDB is a **sampled estimate, not a count**, and it drifts by more than
people expect. Both figures re-read on 2026-09-07 to make the point:

| Table | `information_schema` estimate | `COUNT(*)` | Error |
|---|---|---|---|
| `items` | 82,620 | 83,824 | −1.4% |
| `raw_items` | 758,359 | 686,821 | **+10.4%** |

Every row count in this document is now a `COUNT(*)`. Byte figures are still `data_length`
and `SUM(LENGTH(...))` respectively, which is why the two do not add up to each other —
`data_length` includes page overhead and free space within pages.

So the mechanism was right and the artifact was wrong, in the direction that mattered: the
real table is six times the size of the file being blamed, and it grows every night.

**The healthcheck's event log says the same thing from outside the host.** The `ocb run-all`
check records a start ping and a completion ping, so it measures each run end to end without
depending on anything the dying box managed to write:

| Run | Duration |
|---|---|
| Aug 24 | 11 min 08 s |
| Aug 27 | 11 min 46 s |
| Aug 31 | 12 min 27 s |
| Sep 3 | 13 min 58 s |
| Sep 5 | 13 min 20 s |
| **Sep 6** | **started 03:45, never completed** |

Two things worth having. The run got about 20% slower over twelve days on a job whose work
is supposed to be one day's items — which is what an unbounded `since=all` against a growing
table looks like from the outside, and it means the margin was shrinking on its own rather
than the Sep 6 run being unlucky. And Sep 6 is not a slow run or a failed run: it is a run
that never returned, matching a log that stops mid-statement at 03:46:47.

The alerting worked. The check went `up ➔ down` at 05:45, two hours after the start ping, and
emailed. That is the mechanism the memory cap in
[section 3](#3-memory-headroom-on-the-primary--and-why-more-swap-is-the-wrong-lever) relies on
to tell you it killed something, which is why the token rotation there matters: a leaked ping
URL lets anyone post the success that suppresses this email.

This table is recorded here because rotating the leaked token means replacing the check, and
the replacement starts with an empty event log.

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

66 milliseconds, no files produced. A *post*-backup hook cannot fire when the backup never
runs, so **no hook fix restores uploads through the scheduled path until this is
repaired**. An earlier revision said that without the qualifier, which read as though
nothing could produce a backup until DirectAdmin's task queue was fixed. That turned out
to be the wrong conclusion to draw: `admin-backup --user=` runs in the foreground and does
not go through the task queue at all, and on 2026-09-07 it archived and uploaded eleven
accounts with `Not implemented` still failing every morning. Repairing the stored job is
therefore not a prerequisite for having backups — see
[the batching section](#per-account-backups-da_backup_batchsh) — and the stored job is now
something to [delete](#3-delete-directadmins-backup-schedule--this-one-needs-the-panel)
rather than repair. Corroborating:
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
of the preceding week, and a successful run needs about 5 GB of anonymous memory on a box
that has 3.8 GB of RAM — measured below. The margin on a good night is a few hundred
megabytes. Another 4 GB of swap buys a few more nights of the same graph.

A note on how this claim moved, because the correction is instructive. An earlier revision
said the load came from a database that grows. Then `oncallbrief.db` turned out to have an
mtime of Feb 2026, so the claim was withdrawn as unsupported. Both readings were wrong in
the same way — they assumed the SQLite file was the store. It is not; MySQL is. The growth
claim is now restored with numbers behind it: `raw_items` gains **~3,600 rows and ~16 MB of
`raw_text` every day**, and `since=all` reads all 683,188 of them.

That still does not, by itself, explain why Sep 5 completed and Sep 7 did not. Two days of
ingest is about 1.2% more data, and the memory needed rose by considerably more than 1.2%.
The honest reading is in the cap sizing below: the per-night figures come from `sar`'s
ten-minute samples, which record where the run happened to be at 03:50, not its peak.

In order of leverage:

1. **Bound the query.** This is the actual defect. In `oncallbrief/store.py`,
   `get_raw_items_not_yet_deduped()`:

   ```python
   cur = conn.execute("SELECT * FROM raw_items ORDER BY created_at DESC")
   rows = cur.fetchall()
   out = [r for r in rows if (r["id"] if isinstance(r, dict) else r[0]) not in linked_ids]
   ```

   `SELECT *` pulls `raw_text` — 2,650 MB across 683,188 rows — and `fetchall()` materializes
   every row in Python before a single one is filtered. As Python objects that inflates
   several times over, which is the whole memory footprint.

   The number that matters is what survives that filter. Counted on the primary on
   2026-09-07: **174 rows, together holding under 1 MB**. The function reads 683,188 rows and
   2.65 GB to return 174 of them. It is not that the query is somewhat too broad — it is that
   the filter runs in the wrong place, so the cost tracks the size of the table instead of the
   size of the backlog. That is also why the failure arrived suddenly rather than gradually:
   nothing about the nightly workload changed, the table simply crossed what 3.8 GB of RAM
   could hold.

   **Correction to an earlier revision of this document,** which claimed `run_dedupe` never
   reads `raw_text` and that naming columns would therefore drop 2.6 GB for free. It does read
   it, in two places, and both would have failed quietly:

   - `raw_text` from each group's identity row becomes the merged item's body. `upsert_item`
     assigns `raw_text = VALUES(raw_text)` unconditionally for unbriefed rows, so a version
     that stopped loading the column would not have errored — it would have **blanked the body
     of every item it merged**.
   - `_choose_identity_row` tie-breaks on `len(raw_text)`. Without the column every candidate
     scores zero and the winning row changes, silently altering which title, URL and body a
     merged item takes.

   Both are cheap to keep once they are known: select `LENGTH(raw_text)` for the tie-break,
   and fetch the bodies only for the identity rows, in batches.

   This lives in
   `/home/tellerstec/public_html/wp-content/plugins/tellerstech-landing/oncallbrief-pipeline`,
   not in this repository.
2. **Cap the job so it dies alone.** This is the availability fix and it is independent
   of (1) — it converts "host unreachable for five hours" into "one cron job failed".

   The obvious form of this does not work, and fails in a way that looks like the cap
   working. Wrapping the existing line in `systemd-run --scope -p MemoryMax=…` inside
   `crontab -u tellerstec` runs `systemd-run` as an unprivileged user against the **system**
   manager, which needs root or an interactive polkit agent. Cron has neither, so it exits
   before Python starts. The pipeline stops running entirely, and the first symptom is a
   missed healthcheck — which reads like the cap doing its job, and invites someone to
   remove the wrapper and restore the uncapped command.

   Install it as a root-owned unit instead, so the limits are set by the same manager that
   starts the process:

   ```ini
   # /etc/systemd/system/oncallbrief.service
   [Unit]
   Description=oncallbrief pipeline (memory-capped)

   [Service]
   Type=oneshot
   User=tellerstec
   MemoryAccounting=yes
   MemoryMax=2600M
   MemorySwapMax=3400M
   EnvironmentFile=/etc/oncallbrief.env
   ExecStart=/bin/bash -lc 'cd /home/tellerstec/public_html/wp-content/plugins/tellerstech-landing && python3 oncallbrief-pipeline/run_all.py >> /home/tellerstec/logs/oncallbrief.log 2>&1'
   ```

   The ping URL goes in `/etc/oncallbrief.env`, never in the unit and never in this repo:

   ```bash
   sudo install -m 0600 -o root -g root /dev/null /etc/oncallbrief.env
   sudo tee /etc/oncallbrief.env >/dev/null <<'EOF'
   RUN_ALL_HEALTHCHECK_URL=https://hc-ping.com/<new-uuid>
   EOF
   ```

   Two reasons it is a separate file rather than a value in the unit. Unit files under
   `/etc/systemd/system` are world-readable, and `systemctl cat`/`show` will print them for
   any local user. And an inline `VAR=value python3 ...` inside `bash -lc` puts the URL in
   the process command line, where `ps aux` exposes it to every account on a shared hosting
   box for the length of the run. systemd reads `EnvironmentFile` as root before dropping to
   `User=`, so a 0600 root-owned file works while staying out of both. The variable then
   lives only in the process environment, and `/proc/<pid>/environ` is readable just by the
   process owner and root.

   `sudo systemctl show oncallbrief -p Environment` will echo the value back, so treat that
   command as equivalent to printing the secret.

   **Use the URL of a replacement check here.** The URL previously in this file — the
   `ocb run-all` check, ping URL beginning `24677487` — was committed to a public
   repository. Removing it from the working tree did not unpublish it; it is still in this
   branch's history. A ping URL is a write capability, so anyone holding it can post a
   success and suppress the missed-run alert that this whole step depends on to notice a
   killed job.

   A check's UUID is immutable and healthchecks.io has no regenerate action, so rotating
   means replacing the check. **Create a Copy…** on the check's details page carries over
   the name, tags, description, schedule, filtering rules and notification methods, and
   issues a new ping URL:

   1. **Create a Copy…** on `ocb run-all`. Confirm the copy's period is 1 day and its grace
      is 2 hours, since those are what turn a killed run into an email.
   2. Put the copy's URL in `/etc/oncallbrief.env` and start the timer.
   3. Wait for one real run to report OK on the copy — or
      `curl -fsS "$RUN_ALL_HEALTHCHECK_URL"` by hand — before going further. Deleting the
      old check first would leave a window with no alerting at all on this job.
   4. **Delete the old check.** Until it exists, the leaked URL still reaches something.

   The copy starts with an empty event log, so the old check's history goes with it. That
   history is evidence for this incident — see the runtime trend below — so capture
   anything you want to keep before step 4.

   ```ini
   # /etc/systemd/system/oncallbrief.timer
   [Unit]
   Description=Run the oncallbrief pipeline nightly

   [Timer]
   OnCalendar=*-*-* 03:45:00
   Persistent=true

   [Install]
   WantedBy=timers.target
   ```

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now oncallbrief.timer
   crontab -u tellerstec -l                     # review, then remove the old 03:45 line
   crontab -u tellerstec -e
   ```

   Leaving the cron entry in place alongside the timer gives two concurrent copies of the
   job, one of them uncapped, which is worse than either alone. Remove it in the same
   sitting.

   **There are two `run_all.py` entries in that crontab, not one.** Read on the primary
   2026-09-07:

   ```text
   45 3 * * *   ... RUN_ALL_HEALTHCHECK_URL=<leaked> python3 oncallbrief-pipeline/run_all.py
   45 2 * * 1   ... RUN_ALL_HEALTHCHECK_URL=<leaked> python3 oncallbrief-pipeline/run_all.py --week previous
   ```

   The Monday 02:45 catch-up pings the **same** check and carries the **same** leaked URL,
   so replacing only the nightly line leaves the exposed token live on the box and leaves a
   second uncapped entry racing the timer. Its memory cost is usually nil — `sar` for Aug 31
   02:40–03:00 is flat, and its log shows it exiting in under a second with
   `brief already looks complete ... skipping ingest, summarize, and draft`. That is
   conditional, though: on a Monday where the previous week's brief is *missing* it does the
   full ingest and summarize, which is the expensive path. Give it its own
   `oncallbrief-catchup.service` with the same limits and an `OnCalendar=Mon *-*-* 02:45:00`
   timer, or drop it, but do not leave it in cron.

   A third entry, `*/20 * * * *` running `oncallbrief.send_siw`, uses a different check whose
   URL was never committed here. It needs no rotation and is untouched by this step.

   **Where those two numbers come from, and why `MemorySwapMax=0` is wrong here.** An
   earlier draft of this section said `MemoryMax=1200M` and `MemorySwapMax=0`, reasoning
   that swap is the medium the thrash happens in so the job should be denied it. Measuring
   what a *successful* run costs shows that would have killed the pipeline on its first
   night. From `sar -r` and `sar -S` on the nights the job completed normally:

   | | 03:40 baseline | 03:50 mid-run | pipeline's share |
   |---|---|---|---|
   | Sep 3 | 1.33 GB used, 0.59 GB swap | 3.36 GB used, 3.87 GB swap (96.7%) | ~2.0 GB RAM + ~3.3 GB swap |
   | Sep 4 | 1.35 GB used, 0.55 GB swap | 3.20 GB used, 3.36 GB swap (84.0%) | ~1.9 GB RAM + ~2.8 GB swap |
   | Sep 5 | 1.42 GB used, 0.54 GB swap | 3.40 GB used, 3.23 GB swap (80.7%) | ~2.0 GB RAM + ~2.7 GB swap |

   A normal, successful run needs roughly **5 GB of anonymous memory** on a host with 3.8 GB
   of RAM. It only finishes because swap absorbs the ~3 GB that does not fit. `1200M` is a
   quarter of what it needs and `MemorySwapMax=0` removes the medium it depends on: either
   one alone kills every run. That is precisely the failure this section warns about two
   paragraphs earlier — a cap whose first symptom is a missed healthcheck, indistinguishable
   from the cap working, inviting whoever is on call to remove it.

   `2600M` + `3400M` is a 6 GB ceiling against a ~5 GB normal run. It leaves the ~1.8 GB the
   rest of the box needs, gives the pipeline about 20% headroom over its observed cost, and
   still kills a run that heads for the 7.8 GB the machine actually has. Sep 5 succeeded at
   ~5 GB and Sep 6 did not stop — a 6 GB ceiling separates those two.

   **That ceiling was too low, and the reason is worth keeping.** The first capped run, on
   2026-09-07, was OOM-killed inside its cgroup at 03:50:42 — details in the section below.
   The table above is built from `sar`, which samples every ten minutes. It records where a
   run happened to be at 03:50, not where it peaked. Sizing a limit from it systematically
   understates the requirement, and 20% of headroom over a number that is itself an
   underestimate is not headroom at all. Nothing in the table was wrong; it was the wrong
   instrument for the question, and picking a kill threshold from sampled data was the
   error. A peak needs `systemd-cgtop`, `memory.peak` from the cgroup, or a one-second
   sampler alongside the run.

   **This is survival, not headroom.** The cap keeps a bad night from taking the host with
   it; it does not create room that is not there. A job needing 5 GB of a 7.8 GB box every
   single night, with swap at 81–97% each time, has no margin for a slow API or a slightly
   larger week — which is what Sep 6 was. Bounding the query is the fix; until then a
   `t3a.large` (8 GB, roughly +$27/month) is the lever that actually restores margin.

### The first capped run: 2026-09-07 03:45

**The cap did what it was installed to do.** The job died alone and the host stayed up.

```text
Result=oom-kill                 ExecMainStatus=15   (killed, signal=TERM)
started  Mon 2026-09-07 03:45:01 EDT
killed   Mon 2026-09-07 03:50:42 EDT      after 5 min 41 s, 2 min 5 s of CPU

kernel: oom-kill:constraint=CONSTRAINT_MEMCG, oom_memcg=/system.slice/oncallbrief.service
kernel: Killed process 401670 (python3) total-vm:6663628kB anon-rss:2563704kB
```

`CONSTRAINT_MEMCG` is the whole point: the kill was scoped to the service's own cgroup, not
to the machine. Compare the two mornings directly — `/var/log/messages` went from 2,897 lines
in the 03:00 hour to **1** in the 04:00 hour on Sep 6, the box unreachable for five hours. On
Sep 7 the 03:00 hour has 1,670 lines, the 04:00 hour is logging normally, `uptime` shows no
reboot, and load average at 04:07 is 0.23. One failed cron job instead of an outage. That
was the objective and it is met.

The newsletter did not run, which is the cost. `anon-rss` at kill was 2,563,704 kB against a
`memory.max` of 2,662,400 kB — pinned at 96% of the RAM limit — with swap at 74.4% and
climbing when `sar` last sampled it. The job wanted more than the 5.86 GiB the two limits
allow together.

Because `MemoryMax` bounds only what the pipeline can hold in RAM, the rest of the host keeps
its ~1.2 GB no matter how badly the job behaves. That property is what makes raising
`MemorySwapMax` a materially different proposition from removing the cap: swap can grow
without the host losing the memory it needs to stay reachable. The disk freed in step 2 makes
a larger swapfile practical for the first time.

Three ways forward were on the table. **Only the third was taken, and it made the other two
unnecessary.** Recording all three, because the reasoning for dropping two of them is the
useful part:

1. ~~**Let it complete once.** Add swap and raise `MemorySwapMax`.~~ **Not done, and should
   not be.** This was a way to buy a completed run without fixing anything, and its stated
   purpose — to obtain the peak figure `sar` could not give — is now served by a run that
   fits. The fixed pipeline peaks at 667 MB and touches swap zero times, so more swap would
   only widen the window in which a future regression can thrash the disk instead of failing.
   The existing `2600M` / `3400M` pair is left exactly as it is: it is a safety cap, not a
   budget, and the job now runs at 26% of it.
2. ~~**Shrink the payload.** Blank `raw_text` for rows past a retention horizon.~~ **Not done,
   and should not be.** This was destructive, irreversible, and aimed at a cost that no longer
   exists — the 2,650 MB is simply never read now. Deleting seven months of article bodies to
   speed up a query that no longer touches them would have been the worst possible trade. A
   retention policy may still be worth having for disk and backup reasons; it is not an
   incident fix and should not be justified by this incident.
3. **Fix the query.** Done — see below. The only option that stops the problem returning as
   the table grows by its 16 MB a day.

### What the fix does, and what it measured

Two changes in the pipeline repo (`TellersTechOrg/tellerstech-website`), in
`oncallbrief/store.py` and `oncallbrief/ingest.py`:

- `get_raw_items_not_yet_deduped` now resolves **ids** first, subtracts the linked set, and
  only then reads the rows that survived — in batches, and without `raw_text`.
- That id scan is **streamed, not `fetchall`ed**. It still visits one row per row in the
  table, but only the surviving ids are kept; materializing the other 686,647 as connector
  row dicts cost more than every surviving row put together.
- The bodies the merge genuinely needs — one per group, for the identity row — are fetched
  by `get_raw_item_texts` a batch of groups at a time, so the merge holds a bounded number of
  them however far behind dedupe has fallen. `LENGTH(raw_text)` rides along with each row so
  `_choose_identity_row`'s tie-break is unchanged.
- `get_items_identity_stubs` stops loading `items.raw_text` (157 MB) that neither of its two
  callers reads. Its docstring already claimed the rows were lightweight.

Measured on the primary, 2026-09-07:

| | Before | After |
|---|---|---|
| Dedupe pass (`since=all`) | OOM-killed at 2600M RAM + 3400M swap | **315 MB peak**, 21 s, under a 1500M cap with **swap disabled** |
| Whole nightly pipeline | never reached step 3 | **667 MB peak**, swap peak **0 bytes**, exit 0 |
| Read to merge 174 rows | 683,188 rows / 2.65 GB | 686,821 ids, then 174 rows |

(683,188 is the count taken during the analysis; 686,821 is the count after that day's
ingest landed. Same table, three thousand rows apart, not two conflicting readings.)

Correctness was checked against the pre-run backup of `items`, restored into a scratch
schema and joined row by row: across all 83,479 pre-existing items, **zero lost their body**.
The 42 rows whose `source_ids` grew and the handful whose title or URL improved are
`merge_item_for_upsert` doing its documented job on unbriefed rows.

### What is *not* bounded by the backlog

An earlier revision of this section claimed the cost is now "proportional to the backlog
rather than to the table". That is too strong, and the numbers in the table above say so:
686,821 ids are still visited to find 174 rows. Two components still scale with the table,
measured on the primary by running the id scan both ways, twice each, read-only:

| | Peak RSS | Time |
|---|---|---|
| Linked-id set alone (`_get_linked_raw_ids`, 706,924 ids) | 94 MB | 4.3 s |
| Id scan with `fetchall()` | 303 MB | 8.3 s |
| Id scan streamed | **94 MB** | 11.4 s |

So streaming removes 209 MB — the whole cost of materializing the scan — and buys it for
about three seconds. What it cannot remove is the 94 MB floor: `_get_linked_raw_ids` parses
every `items.source_ids` CSV into one Python set, and that set is inherently one entry per
linked raw row. At ~3,600 new ids a day it grows roughly 170 MB a year.

Against a 2600 MB cap that is years of runway, not a bound. The change that would make the
claim true is a schema one: normalize `source_ids` into an `item_raw_links` join table so
the exclusion becomes a `LEFT JOIN` and no Python set is built at all. Worth doing before
the floor gets interesting; not worth doing during an incident.

Also proven offline before deploying, on a database seeded to the same shape at 1/34 scale:
the merged `items` table came out **byte-identical** between the old and new code, including
every `raw_text`, while peak RSS fell from 638 MB to 67 MB. Both halves of the change were
individually reverted to confirm the comparison actually fails when they are missing — the
tie-break revert changes which row wins, and the body-fetch revert blanks bodies.

Six regression tests covering this live in the pipeline repo at
`tests/test_dedupe_backlog.py`.

   **Confirm the limits took effect.** `MemorySwapMax` is silently ignored under cgroup v1:

   ```bash
   stat -fc %T /sys/fs/cgroup          # cgroup2fs = both enforced; tmpfs = v1, swap cap ignored
   systemctl show oncallbrief.service -p MemoryMax -p MemorySwapMax
   sudo systemctl start oncallbrief.service && systemctl status oncallbrief.service
   ```

   Checked on the primary 2026-09-07: `cgroup2fs`, so both limits are enforced. On a v1 host
   the swap limit is dropped and the RAM limit alone permits the same thrash, so either boot
   with `systemd.unified_cgroup_hierarchy=1` or accept that the cap is partial.

   A run that exceeds the cap shows as `code=killed, status=9/KILL` in `systemctl status`.
   The healthcheck ping doubles as the alert: a killed run never pings, so it surfaces as a
   missed check without new monitoring.
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

**Run every command in this section as root.** The rclone remote is defined in
`/root/.config/rclone/rclone.conf` and nowhere else, so as `tellerstec` the first command
fails with:

```text
NOTICE: Config file "/home/tellerstec/.config/rclone/rclone.conf" not found - using defaults
CRITICAL: Failed to create file system for "s3backup:...": didn't find section in config file ("s3backup")
```

That is the remote being undefined for that user, not a credential or connectivity problem —
and it is safe, because it fails before transferring anything. `/backup` is root-owned anyway,
so the reads need root regardless.

**Do not delete anything under `/backup` before it is in S3.** Those nine directories are
the only copy. Confirm for yourself first:

```bash
aws s3 ls s3://wbat-tellerstech-directadmin-backups-708113892725/server/
```

If nothing newer than `2026-07-02/` appears, upload before deleting. Note the ordering:
`08-29-26` goes first because it holds the only recent database dump, and a lexicographic
glob would otherwise leave it until last.

**Checked 2026-09-07: "only copy" is measured, not inferred.** The `server/` prefix holds 47
dated prefixes and stops at `2026-07-02/`. Every one of the nine local weeks was queried
directly — both the `MM-DD-YY` date and the day after, in case of a cross-midnight write — and
every one returned **zero objects**:

```text
2026-07-04 … 2026-08-30, 2026-09-05, 2026-09-06 → objects=0 (20 prefixes, all empty)
```

What is on disk, and what each week is worth:

| Week | Total | `mysql/` |
|---|---|---|
| 07-04-26 … 08-15-26 | 6.2–6.7 GB each | 1.4–1.8 GB each |
| 08-22-26 | 7.4 GB | 1.8 GB |
| **08-29-26** | **7.4 GB** | **1.9 GB — newest database dump anywhere** |
| 09-05-26 | **60 KB** | **none** |

That last row is the config-only regression measured directly rather than inferred from a log:
the Sep 5 system backup produced 60 KB and no `mysql/` tree at all, while every week before it
carried 1.4–1.9 GB of databases.

### Step 2 completed 2026-09-07 06:21 UTC

All ten weeks are in S3 and the eight redundant local copies are gone. `rclone check --checksum
--one-way` passed on every week before anything was deleted; the bucket was then read back
independently:

| Prefix | Objects | Bytes | `mysql/` bytes |
|---|---|---|---|
| 2026-07-04 | 136 | 6,578,804,826 | 1,423,050,939 |
| 2026-07-11 | 136 | 6,647,740,587 | 1,488,486,131 |
| 2026-07-18 | 136 | 6,767,112,530 | 1,569,866,385 |
| 2026-07-25 | 136 | 6,865,878,810 | 1,653,156,153 |
| 2026-08-01 | 136 | 6,923,510,424 | 1,707,039,242 |
| 2026-08-08 | 136 | 7,042,539,440 | 1,775,345,804 |
| 2026-08-15 | 136 | 7,106,980,350 | 1,843,950,635 |
| 2026-08-22 | 136 | 7,848,011,628 | 1,911,713,351 |
| 2026-08-29 | 136 | 7,908,696,346 | 1,982,103,443 |
| 2026-09-05 | 2 | 55,126 | — |

59.3 GiB, against a local `du -sh /backup` of 60 G. The check worth making here is not that the
totals agree — a checksum pass already establishes that — but that **each week is strictly larger
than the one before it, databases included**. That rules out the failure where one source
directory is uploaded nine times under nine names and every checksum passes because it really is
the same data. These are nine distinct weekly backups of a system that grew, plus the 55 KB
config-only week.

`server/` now runs unbroken from `2026-07-02` to `2026-09-05`, and the first upload landed
2026-09-07 05:34 UTC — 67 days after the last one.

```text
/dev/nvme0n1p2  200G  146G   55G  73% /      (was 197G used, 3.8G free, 99%)
/backup: 08-29-26, 09-05-26 -- 7.4G
```

`08-29-26` was deliberately kept on disk, so the newest databases now exist both locally and in
S3. `09-05-26` was uploaded despite being worthless as a backup: left local and unreplicated it
ages past seven days on Sep 12, the sweep correctly refuses to delete what it cannot confirm,
and it emails about it on every run from then on. A backstop that cries wolf is one people learn
to ignore — the same argument as the cross-midnight prefix fix.

One reading note: `df -i` shows apparent total inodes going from 8.7 M to 104 M across this
change. That is XFS estimating dynamically from free space, not anything about the filesystem
changing.

**`rclone lsd s3backup:` returns 403 and that is correct.** It calls `ListAllMyBuckets`, which
the `directadmin-backup` IAM user is deliberately not granted; its policy allows `ListBucket`,
`GetBucketLocation` and `ListBucketMultipartUploads` on this bucket only, plus `PutObject`,
`GetObject`, `DeleteObject` and the multipart actions on its objects. That is exactly what
`rclone copy` and `rclone check --checksum --one-way` need, and it is why every command below
passes `--s3-no-check-bucket`. The 403 reads like broken credentials at one in the morning;
list the bucket path instead of the remote root to see the real state.

**A caveat on the gate below, added 2026-09-08.** `rclone check --checksum --one-way` is
what these commands use to decide a local copy is safe to delete, and it is not sufficient
on its own — it proves S3 holds the same bytes, not that those bytes are a whole archive.
That is the [`tellerstec` failure](#the-first-real-run-2026-09-07-2215-edt) in miniature.
For an upload of files that have been sitting at rest for weeks the risk is much lower than
for one taken straight from a live producer, and
[the read-back sweep](#is-what-is-already-in-s3-readable-a-read-back-of-every-archive-2026-09-08)
has since confirmed all ten weeks uploaded this way are readable. But if you are following
these commands again, read the archives back before deleting anything:

```bash
./aws/docs/verify-s3-archives.sh --quick --prefix "server/${iso}/"     # cents
./aws/docs/verify-s3-archives.sh --full  --prefix "server/${iso}/"     # whole-object egress
```

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
cd /root/wbat-terraform && git fetch origin && git merge --ff-only origin/main
sudo ./scripts/directadmin/install_da_vhost_listen.sh --install
./scripts/directadmin/install_da_vhost_listen.sh --verify
/usr/local/sbin/da-disk-guard.sh --report
```

`--ff-only` rather than `git pull`: the host checkout is a deploy target, not a place to
resolve a merge. If it will not fast-forward, something has been edited on the box and that
is the thing to find out about — which is the same failure `--verify` catches downstream.

`--verify` matters: the primary's hook was hand-edited and matched no commit, so a merged
fix would not otherwise have been running.

Note what `--install` now covers. As well as the two hooks and the disk guard, it installs
`da-backup-batch.sh` and `/etc/cron.d/da-backup-batch`, so running it schedules account
backups at 01:00. That is the intended outcome, but it means DirectAdmin's own schedule
should be [deleted](#3-delete-directadmins-backup-schedule--this-one-needs-the-panel) in the
same sitting rather than afterwards.

## DirectAdmin remediation — what to run, and what needs the panel

**Prerequisite: [free the disk first](#recovering-space-safely).** Everything below either
writes archives to the root volume or is pointless without somewhere to put them, and when
this was written the volume had 3.8 GB free. **That step is done** — `/` is at 71% with
59.8 GiB free — so this is here as the reason for the ordering rather than as work
outstanding. It did not buy enough headroom for a full run; see below.

### 1. Prove the backup engine works without filling the disk (CLI)

DirectAdmin can run an admin backup in the foreground, bypassing the task queue that the
scheduled job goes through. Scope it to **one small account**, because a full run writes
every account's archive to local disk before the post-backup hook gets a chance to upload
anything:

```bash
/usr/local/directadmin/directadmin admin-backup --destination=/home/admin_backups --user=test2
```

`test2` was under 2 MB in the last successful backup, so it proves the whole chain — engine
writes, hook fires, objects land in S3, local copy is removed — for kilobytes. Any small
account does; list candidates by size with `du -sh /home/*/` rather than hardcoding names,
since account sizes drift. Check all four stages, not just the command's exit status:

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

**This was run on 2026-09-07 and it succeeded**, which settled the split: `--user=test2`
completed in 2.4 seconds, the hook uploaded and verified the archive and removed the local
copy, and the whole chain took three seconds. The engine is not broken. Only the
all-at-once staging is, which is what the batching section below addresses.

**On the eventual full run — it no longer fits.** `all_backups_post.sh` is DirectAdmin's
*all backups* hook. It fires once, after every account has been archived, so every archive
is on local disk at the same time, and on top of that DirectAdmin holds the assembled parts
of whichever account it is currently building. The last full run that completed, on
2026-07-02, put **66.055 GiB across 13 objects** into S3, and the accounts have grown since
(`teller` alone is 54.0 GiB of the 114 GiB of home directories). The cleanup in step 2 of
the order above, plus the `/backup` reclaim on 2026-09-07, leaves **59.8 GiB free**.

The sum of the finished archives alone already exceeds that, so a full run fails on this
volume before the parts overhead is even counted — and counting it makes the requirement
worse, by roughly the size of the largest account again. Either way the run drives the
volume to 100% before the hook ever gets to upload anything, which is the outage this
document exists to prevent.

So do not schedule a full local run on this volume. Three ways out were considered:

- **Batch it.** Repeated `--user=` runs, one account at a time, letting the hook upload
  and clear each before the next. Peak usage becomes the largest single account.
- **Move the upload per-user.** DirectAdmin's `user_backup_post.sh` hook fires after each
  account, so each archive is uploaded and deleted as it is produced. Same peak as
  batching — 43.4 GiB for `teller` at the last measurement, and on the corrected model
  about twice that, which is why neither approach reaches it — but it changes which hook
  owns the upload and therefore reopens every data-loss question `all_backups_post.sh`
  already answers.
- **Give it somewhere else to write.** A separate EBS volume mounted at
  `/home/admin_backups` decouples staging from the root filesystem, at ongoing cost, and
  does nothing about an account that outgrows the new volume either.

**Batching is what was built** — see the next section. It reuses the existing hook
unchanged, so none of the verified-before-delete work has to be re-established, and it
needs no new infrastructure.

## Per-account backups: da_backup_batch.sh

[`da_backup_batch.sh`](../../scripts/directadmin/da_backup_batch.sh) replaces
DirectAdmin's own schedule with a run that archives one account at a time and waits for
`all_backups_post.sh` to upload and clear each one before starting the next. Peak local
usage becomes the largest single account instead of the sum of all thirteen. On this host
that turned out to be enough for eleven accounts and not for the other two; the
[first real run](#the-first-real-run-2026-09-07-2215-edt) has the numbers.

**Thirteen, and why it is easy to read as fourteen.**
`/usr/local/directadmin/data/users` has fourteen entries, but one of them is a stray
`fix.sh` — a 257-byte script from April 2023, owned by root, sitting among the account
directories. It has no `user.conf`, and `known_users()` in the batch script requires one
precisely so that name is never passed to `--user=`, where DirectAdmin would fail the
whole batch on an account that does not exist. Counting directory entries therefore gives
one more than the number of accounts. DirectAdmin's own lists agree on thirteen: `admin`
itself, `wbatnet` and `tellerstec` as its resellers, `fcsar` and `wbat` under `admin`, and
`alumnibhs`, `aubrey`, `brian2`, `feed2js`, `littelman1`, `signera`, `teller` and `test2`
under `wbatnet`. So does the 2026-07-02 full run, which produced exactly thirteen objects.
Eleven archived plus the two that do not fit is the whole estate, with nothing
unaccounted for.

The premise was checked before anything was built. On 2026-09-07,
`directadmin admin-backup --destination=/home/admin_backups --user=test2` completed in
2.4 seconds, produced `user.wbatnet.test2.tar.zst`, and the hook uploaded it, verified it
against S3 and deleted the local copy — the entire chain, unmodified, in three seconds.
The engine is not broken. Only the all-at-once staging is.

Two guards, because the size estimate is the part most likely to be wrong:

- **Before** each account, its estimated peak plus a 10 GB reserve must fit in the free
  space that exists at that moment. The estimate is the archive — 100% of the account's
  home directory, deliberately pessimistic against a measured 28–84% — **taken twice
  over**, because DirectAdmin needs room for two copies rather than one. That doubling is
  not a safety margin; it is what the tool does, and leaving it out is what let the first
  real run start an account the volume could not hold. See
  [the first real run](#the-first-real-run-2026-09-07-2215-edt) for the measurement.
- **During** each account, a watchdog samples free space and kills the backup if it
  crosses an 8 GB floor. An estimate from `du` cannot know about a database that grew or a
  compression ratio that got worse; the floor does not need to know why. The same floor is
  checked before starting, so a volume that is already below it produces a skip that says
  so rather than a backup that is launched and killed a second later.

  A kill has to reach the upload hook, not just the compressor. DirectAdmin runs
  `all_backups_post.sh` itself, from inside the `admin-backup` invocation, **including when
  the archive step failed** — so the hook empties the staging directory before this script
  gets control back, and deleting the partial after the child exits is too late by
  construction. The watchdog therefore writes `/run/da-backup-abort` *before* it signals
  anything, and the hook checks that file first and touches nothing. The script refuses to
  start at all if it cannot write the sentinel, because a guard that is silently absent
  looks exactly like a working one until the first floor breach.

Both of those guards watch space, and a backup can fail without using any. An `rclone`
inside the upload hook that stops making progress against S3, or DirectAdmin blocked on a
database lock, hangs at constant free space, and waiting on the child process is otherwise
unbounded. A run stuck there also holds the batch lock, so every cron invocation after it
takes the "another run holds it" branch and exits 0 — account backups would stop
completely and nothing would mail, which is the same silence that hid the July failure for
two months. So each account is additionally bounded by a **six-hour limit**: past it the
process group is terminated, the archive it left behind is deleted, and the run reports
itself incomplete. The lock branch is the other half: a holder is still skipped quietly,
which is right for an overlap of minutes, but one that has kept the lock for more than a
day is mailed rather than taken as a reason to exit 0 again.

A run that selects **no account** is treated the same way, for the same reason. The backup
loop reads from a generator, so an empty selection is not an error to it — it is a loop
body that never executes, after which the summary finds nothing failed and nothing skipped
and exits 0. A typo in `--user=` produces that, and so does a users directory that has
moved, been renamed, or become unreadable to the account cron runs this as. The second is
the one that matters: it is silent and it takes out every account at once, which is the
2026-07-02 failure with a different mechanism.

Accounts run smallest first, so a failure on the accounts least likely to fit leaves the
rest already safe in S3 rather than never attempted. That ordering earned its place on the
first real run: `tellerstec` failed, and the eleven accounts ahead of it were already
uploaded. A run that skips or fails anything exits non-zero and mails `HEALTH_ALERT_TO`
naming the accounts that now have no backup.

```bash
/usr/local/sbin/da-backup-batch.sh --list      # sizes, and what fits right now
/usr/local/sbin/da-backup-batch.sh --dry-run
/usr/local/sbin/da-backup-batch.sh --user=teller
```

`/etc/cron.d/da-backup-batch` runs it daily at 01:00 — clear of the oncallbrief pipeline
at 03:45 and the weekly system backup at 05:00. **DirectAdmin's own schedule must be
deleted** at Admin Level → Admin Backup/Transfer → Schedule, or the two race at 05:00.

[`prove_backup_batch.sh`](../../scripts/directadmin/prove_backup_batch.sh) pins the
behaviour offline against a stubbed DirectAdmin, `df` and `mail`: ordering, the headroom
gate and its doubling, the reserve, refusing to start on a dirty staging directory,
waiting for the drain, the floor kill and its partial cleanup, the abort sentinel in all
three of its states — written before the signal, cleared afterwards, and unwritable — and
the per-account time limit. The stubbed DirectAdmin runs a stand-in upload hook from its
own `TERM` handler, so the sandbox has the same ordering the host does. Non-vacuity checks
remove each guard in turn and confirm the matching proof then fails.

### The first real run: 2026-09-07 22:15 EDT

Run by hand under `systemd-run`, watched throughout. It is the reason two of the guards
above look the way they do.

**Eleven of the thirteen accounts were archived, uploaded, verified and cleared**, in
17m56s, in ascending size order, with the staging directory confirmed empty between each
one:

| Account | Home | Archive | Ratio |
| --- | --- | --- | --- |
| signera, test2, brian2, fcsar, aubrey | < 0.1 GiB each | 18.9 MiB, 612 KiB, 520 KiB, 785 KiB, 1.2 MiB | — |
| wbat | 0.1 GiB | 21.6 MiB | — |
| littelman1 | 0.6 GiB | 218 MiB | 35% |
| alumnibhs | 4.2 GiB | 3.51 GiB | 84% |
| feed2js | 4.9 GiB | 1.40 GiB | 28% |
| admin | 6.2 GiB | 3.08 GiB | 50% |
| wbatnet | 10.5 GiB | 6.72 GiB | 64% |

14.96 GiB across 11 objects under
`s3://wbat-tellerstech-directadmin-backups-708113892725/server/2026-09-07/`. These are the
first account backups since 2026-07-02.

Then it went wrong on `tellerstec`, and the way it went wrong was worse than failing.

The pre-flight gate estimated 33.4 GiB against 59.8 GiB free and started it. At 22:49:29
the watchdog found free space at 8.0 GiB — 51.8 GiB consumed against an estimate of 33.4 —
and killed the process group. DirectAdmin reported `Error Compressing the backup file
reseller.admin.tellerstec.tar.zst`, and then ran the upload hook, which found a 20.02 GiB
fragment in the staging directory, uploaded it over eight minutes, asked `rclone` to
confirm S3 held the same bytes, got told yes, logged `OK admin upload verified in S3`, and
deleted the local copy. Only then did `wait` return in the batch script, whose cleanup
found an empty directory and reported a clean kill.

So S3 gained a truncated archive under exactly the name a complete one would have had, for
the one account whose last good backup is from July. Streaming it back settles it:

```
rclone cat s3backup:…/server/2026-09-07/reseller.admin.tellerstec.tar.zst \
  | zstd -dc | tar -tf - >/dev/null
zstd: /*stdin*\ : Read error (39) : premature end
tar: Unexpected EOF in archive
```

That object has been renamed to
`reseller.admin.tellerstec.tar.zst.TRUNCATED-DO-NOT-RESTORE` rather than deleted: most of
its content is intact and `tellerstec` has nothing newer, so it is worth keeping as a last
resort, but not under a name anyone could mistake for a backup. The bucket's 365-day
expiry removes it on its own.

It is less of a last resort than it looked. The 2026-07-02 archive for `tellerstec` has
since been read end to end and is a whole archive over 57,245 members — see
[the read-back sweep](#is-what-is-already-in-s3-readable-a-read-back-of-every-archive-2026-09-08),
which also found that the 2026-06-29 copy of the same account is itself truncated. So the
fallback for `tellerstec` is nine weeks stale rather than absent, and the fragment above is
a third choice rather than a second.

#### Where the 51.8 GiB went

Measured directly, by sampling `df` and `du` every five seconds through a fresh `wbatnet`
backup. `backup_tmpdir` is `/home/tmp` and stayed empty the whole time — the space is all
in the destination, and this is what is in it mid-run:

```
6964039680  /home/admin_backups/wbatnet/reseller.admin.wbatnet.tar.zst
5784296892  /home/admin_backups/wbatnet/backup/home.tar.zst
 405023869  /home/admin_backups/wbatnet/backup/wbatnet_domains.sql
  40350301  /home/admin_backups/wbatnet/backup/wbatnet_dev.sql
      …     /home/admin_backups/wbatnet/backup/{user.db,*.sql,config}
```

DirectAdmin assembles the account under `<destination>/<user>/` — `backup/home.tar.zst`
first, then a `.sql` dump per database, then `user.db` and the config files — and only once
all of that exists does it tar the lot into
`<destination>/<user>/reseller.admin.<user>.tar.zst`, **in the same directory it is reading
from**. The parts and the archive built out of them are both on disk at the same moment,
and because the parts are already compressed the outer archive is about the same size as
their sum:

| | Home | Archive | Peak on disk | Peak ÷ archive |
| --- | --- | --- | --- | --- |
| wbatnet, measured | 10.50 GiB | 6.72 GiB | 12.69 GiB | 189% |

Hence the 200% in the gate. It also explains why the run's own log looked so healthy: it
records free space *between* accounts, after the drain, so it reported a steady 59.8 GiB
for all eleven — while `wbatnet` had privately dipped to 47.1 GiB. Only the watchdog sees
the in-flight figure.

#### The two largest accounts do not fit, and cannot be made to

On the corrected model, with 59.8 GiB free:

| Account | Home | Archive | Peak needed | Verdict |
| --- | --- | --- | --- | --- |
| tellerstec | 33.4 GiB | ~32 GiB (inferred) | ~64 GiB | does not fit |
| teller | 54.0 GiB | 43.4 GiB (measured) | ~87 GiB | does not fit |

Both peaks are twice the archive, which is the model the `wbatnet` measurement above
establishes. Only one of the two archive figures is measured: `teller`'s July object,
`server/2026-07-02/user.wbatnet.teller.tar.zst`, is 46,585,095,564 bytes — 43.4 GiB, not
43.4 GB, and the distinction matters because it is doubled to reach the peak.
`tellerstec`'s is inferred from the killed run, which had 51.8 GiB on the volume and a
20.02 GiB outer archive written when the floor stopped it; that leaves about 31.8 GiB of
assembled parts, and an outer archive of roughly the same size again.

The gate itself uses neither figure, because when it runs the archive does not exist yet.
It estimates from the home directory — 100% of home for the archive, taken twice over —
which comes out at 66.8 GiB for `tellerstec` and 108 GiB for `teller`. Both are larger than
the table, so the gate skips both accounts a fortiori. The table is the honest lower bound;
the gate is deliberately more pessimistic than it.

Either way **per-account batching gets eleven of the thirteen accounts and cannot get the
other two.** Those two hold 87.4 GiB of the 114 GiB of homes on the host — a figure that happens
to resemble `teller`'s peak above and is not related to it. Lowering the ratio would not help: the gate would
stop skipping them, the floor would kill them mid-run, and — before the sentinel fix —
each kill would publish another fragment to S3. This is a disk problem now, not a
scheduling one. The options are to give `/home/admin_backups` its own volume, to grow the
root volume (200 GB now, 71% used), or to accept that the two largest accounts are backed
up by something other than DirectAdmin. It needs a decision; nothing in this repo makes
one.

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

### 3. Delete DirectAdmin's backup schedule — this one needs the panel

An earlier revision of this section said to recreate this job, and the step above it in
[the order](#do-it-in-this-order) still pointed here to say so. That was written before
the staging arithmetic below was done, and following it now would reintroduce the failure
the batching work exists to prevent. The stored job is `who:[all]`, so a repaired version
of it stages every account's archive on the root volume before the upload hook gets a
chance to remove any of them, and that needs more space than the volume has. Delete it.

The job is not dangerous today, which is why this is easy to leave undone: it fails in
66 ms and produces nothing, and has done every morning since Jul 2. It is a loaded gun in
two directions instead. Whoever eventually diagnoses `Not implemented` and fixes it gets a
full all-users backup at 05:00 the next morning without having asked for one. And
`/etc/cron.d/da-backup-batch`, which step 3 of the order installs, runs at 01:00 — a batch
run that overruns into 05:00 would find DirectAdmin starting a second backup into the same
staging directory, contending for the same hook lock.

Delete it at **Admin Level → Admin Backup/Transfer → Schedule**. There is no documented
CLI command to create, edit *or remove* a scheduled backup: the task queue accepts
`action=backup` for a one-off run and `admin-backup` runs one immediately, but the cron
entry itself is owned by the GUI wizard. `CMD_API_ADMIN_BACKUP` is the scriptable
equivalent; DirectAdmin does not document its full parameter list and suggests running DA
in debug mode to capture what the GUI sends, so the panel is genuinely the lower-risk path
here.

Confirm it is gone from the stored job list and from the daily log, rather than trusting
the panel's success message:

```bash
cat /usr/local/directadmin/data/admin/backup_crons.list     # id=1 should no longer be here
grep 'Running Backup: type=admin' /var/log/directadmin/system.log | tail -3
```

That second line is how to tell the deletion took: it has appeared at 05:00 every day from
Aug 17 onwards, so the useful signal is the first morning it does not.

Then let step 7 produce the backups. The chain to check after a batch run is the same one
this section used to describe, pointed at the producer that now exists:

```bash
tail -40 /var/log/da-backup-batch.log          # which accounts ran, and which did not fit
tail -40 /var/log/da-backup-s3.log             # did the hook upload and verify each one?
ls -la /home/admin_backups/                    # and did it drain between accounts?
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
df -h /                                       # a correct run writes GB; do this after step 2
/usr/local/sysbk/sysbk -q; echo "rc=$?"       # the reverted script, not shared/sysbk.sh
du -sh /backup/"$(date +%m-%d-%y)"            # config-only is ~55 KB; with databases, GB
ls /backup/"$(date +%m-%d-%y)"/               # expect a mysql/ directory
```

Run the script you reverted **to**, not the one you reverted **from**.
`/usr/local/directadmin/shared/sysbk.sh` is the replacement identified above as the thing
that produces the 55 KB config-only archive, so verifying with it reproduces the bug and
looks like the revert failed.

Note that working account backups make this partly redundant: they carry the databases, so
once the batch run is scheduled the system backup matters mainly for server configuration.
Both are worth having. This one is already done — see
[step 4 in the host state below](#state-of-the-host-as-of-2026-09-07-2130-edt) — and it is
the only one of the two that currently covers `tellerstec` and `teller` at all.

## Is what is already in S3 readable? A read-back of every archive, 2026-09-08

**Short answer: the backups anyone would actually restore from are intact, and 22 archives
in the bucket are not.** Every account's most recent readable archive is intact, and the
only one of the 22 that is the newest object for its account is the `tellerstec` fragment
this document already knew about. The current estate
— the eleven account backups written on 2026-09-07, the thirteen from the last full run on
2026-07-02, and all ten weekly system backups from 2026-07-04 to 2026-09-05 — read clean
from first byte to end-of-archive marker.

This had to be checked rather than assumed. The truncated `tellerstec` archive was admitted
by a `rclone check --checksum` that was working correctly: it proved S3 held the bytes it
was handed, which is a different claim from the archive being complete. Every object in the
bucket was admitted under that same rule, and **none had ever been read back.** The hook
fix reads each archive before uploading it, but that only governs objects written from now
on.

Reproducible with [`verify-s3-archives.sh`](verify-s3-archives.sh), which also has an
offline `--self-test` that asserts its own tests fail on a truncated archive.

### What was run, and what it cost

The failure mode is truncation, and truncation is only visible by reading an archive to its
end. There is no shortcut for `.tar.zst`: zstd's per-frame content checksum sits at the end
of a stream you cannot seek into, so proving a zstd archive whole means decompressing all
of it. Reading the entire bucket that way is **775.3 GB of egress, about $77** including
`STANDARD_IA` retrieval, and roughly two hours at the 100–170 MB/s measured against this
bucket. Doing it on the primary instead would avoid the egress and spend the CPU and the
network of a `t3a.medium` that has 2 vCPU and just came back from an outage; streaming
needs no disk, but it needs hours of the box.

So the sweep was split by what each format allows, and run from outside the host:

| | Objects | Bytes read | What it establishes |
| --- | --- | --- | --- |
| Full end-to-end read (`aws s3 cp` → decompress → `tar -t`) | 681 | 264.01 GiB | The object is a complete, well-formed archive and its member list parses to the end |
| gzip trailer, ranged GET of the last 8 bytes | 3,483 | 27 KiB | Necessary condition for an intact `.tar.gz` — see below |

**$27.33** in total ($25.51 egress, $1.82 `STANDARD_IA` retrieval, requests immaterial),
against about $77 to read everything, and about half an hour of wall clock. Nothing was
staged on disk anywhere: `dd` sits in each pipeline on the compressed side purely so the
byte count is an independent assertion that the whole object was pulled, since `tar -t`
consuming its input to end-of-stream is what makes a short count mean "gave up early"
rather than "read and accepted".

**The cheap test, and what it does not rule out.** A gzip member ends with CRC32 then
ISIZE, the uncompressed length modulo 2^32. A tar is always a whole number of 512-byte
blocks, and 2^32 is itself a multiple of 512, so an intact `.tar.gz` has an ISIZE congruent
to 0 mod 512 whatever its real size; truncate the file and those four bytes become deflate
payload, which lands on a multiple of 512 with probability 1/512. That catches truncation
about 99.8% of the time per object for eight bytes instead of gigabytes. It does **not**
verify the CRC, does not see corruption in the middle of a stream, and says nothing about
whether the tar holds a plausible account. Two things bound how much that matters here: the
612 objects of the ten live weekly trees were given *both* tests and the two agreed on
**627 of 627** objects, and every one of the 15 `.tar.gz` objects the trailer test rejected
was then read in full and confirmed unreadable. Nothing passed the cheap test and failed
the expensive one.

**The positive control failed, which is the point.**
`server/2026-09-07/reseller.admin.tellerstec.tar.zst.TRUNCATED-DO-NOT-RESTORE` was read end
to end: `zstd` reports `premature end` and `tar` reports `Unexpected EOF in archive` after
459 members. A test that passed that object would be measuring nothing.

**Coverage.** 3,537 of the bucket's 8,067 objects were tested — every object that is a
compressed container. The remaining 4,530 are 3,467 `.md5` sidecars, 1,056 loose
uncompressed files in an extracted copy of `teller`'s backup tree under
`server/2026-06-30/teller/backup/`, five connectivity-test text files, and two migration
scripts: 0.18 GiB in total. Those loose files are the one real gap — a plain file can be
truncated as undetectably as an archive, and there is no container to parse — but they are
a duplicate of a tree that also exists as an archive.

### What reads clean

| Prefix | Objects | Result |
| --- | --- | --- |
| `server/2026-09-07/` — the eleven new account backups | 11 | **all readable**, all with plausible account structure |
| `server/2026-07-02/` — the last full run | 13 | **all readable** |
| `server/2026-07-04` … `server/2026-09-05` — ten weekly system backups | 612 | **none unreadable**: 540 readable, 72 valid-but-empty |
| `server/2026-06-30/` — top-level account archives | 11 | all readable |
| `server/2026-06-29/` — first migration upload | 14 | 9 readable, **5 unreadable** |

Readability is not the only question for an account backup — a tar can parse and still be
the wrong thing — so each listing was also checked for structure rather than just member
count. All 24 archives across the two current generations hold a `backup/` root, at least
one domain directory, `public_html`, and `user.conf` or `user.db`:

| Account | 2026-07-02 members / domains / SQL dumps | 2026-09-07 members / domains / SQL dumps |
| --- | --- | --- |
| `reseller.admin.wbatnet` | 127,674 / 21 / 12 | 127,702 / 21 / 12 |
| `user.wbatnet.alumnibhs` | 52,580 / 1 / 0 | 52,591 / 1 / 0 |
| `user.wbatnet.littelman1` | 31,665 / 1 / 1 | 31,678 / 1 / 1 |
| `user.wbatnet.feed2js` | 1,758 / 2 / 0 | 1,773 / 2 / 0 |
| `admin.root.admin` | 677 / 1 / 0 | 690 / 1 / 0 |
| `user.wbatnet.test2`, `aubrey`, `brian2`, `signera`, `fcsar`, `admin.wbat` | 199–649 each | 210–670 each |
| `reseller.admin.tellerstec` | 57,245 / 8 / 3 | *(truncated, 459 members)* |
| `user.wbatnet.teller` | **151,865 / 49 / 9** | *(never attempted)* |

**`tellerstec` and `teller` do have a restorable backup, and it is the July one.** The
document has been treating that as an assumption since 2026-09-07 — "the one account whose
last good backup is from July" — and it is now measured.
`server/2026-07-02/reseller.admin.tellerstec.tar.zst` reads clean over 57,245 members
across eight domains with three SQL dumps, and `user.wbatnet.teller.tar.zst`, all 43.4 GiB
of it, reads clean over 151,865 members across 49 domains with nine SQL dumps. They are
nine weeks stale, which is the real problem with them, but they are not empty and they are
not fragments.

The 72 valid-but-empty objects are not a defect in the sweep or in the upload. `sysbk`
archives a fixed list of paths, several of which do not exist on this host, and archiving a
missing path produces a well-formed 45-byte `.tar.gz` containing nothing but tar's
end-of-archive marker. It is the same ten names every week — `custom/etc/master.passwd`,
`custom/etc/proftpd.conf`, `custom/usr/local/frontpage`, `custom/usr/share/ssl` and so on,
379 objects bucket-wide. Worth knowing when reading a manifest; not worth fixing.

One incidental finding, recorded because the name is misleading rather than because it
matters: `server2/2026-07-02/admin.root.admin.tar.zst` is five bytes long and contains the
text `test`. It is a connectivity artefact wearing the name of an account archive. It has
been left alone — it is not a truncated backup, and labelling it as one would be wrong.

### The 22 archives that cannot be read, and what they have in common

| Prefix | Object | Size | Members before it stops |
| --- | --- | --- | --- |
| `server/2026-09-07/` | `reseller.admin.tellerstec.tar.zst` *(known; the control)* | 20.02 GiB | 459 |
| `server/2026-06-30/teller/` | `user.wbatnet.teller.tar.zst` | 43.18 GiB | 141,978 |
| `server/2026-06-29/` | `admin.root.admin.tar.zst` | 1.95 GiB | 230 |
| `server/2026-06-29/` | `reseller.admin.tellerstec.tar.zst` | 1.95 GiB | 22,061 |
| `server/2026-06-29/` | `reseller.admin.wbatnet.tar.zst` | 0.30 GiB | 702 |
| `server/2026-06-29/` | `user.wbatnet.alumnibhs.tar.zst` | 3.30 GiB | 46,765 |
| `server/2026-06-29/` | `user.wbatnet.teller.tar.zst` | 1.81 GiB | 5,222 |
| `server/2026-06-28/` | `custom/home/admin.tar.gz`, `custom/usr/local.tar.gz`, `mysql/full-mysql.tar.gz` | 1.92 / 4.05 / 0.59 GiB | 1,624 / 2,088 / 2,190 |
| `server/2026-03-22` … `2026-06-21` (7 weeks) | `custom/usr/local.tar.gz` | 1.68–4.23 GiB each | 1,866–45,183 |
| `server/2024-09-22` | `custom/usr/local.tar.gz` | 1.36 GiB | 33,802 |
| `server/2024-10-06`, `2024-10-13` | `custom/home/admin.tar.gz` | 1.60 GiB each | 1,025 / 1,046 |
| `server/2024-08-18`, `2024-09-29` | `mysql/full-mysql.tar.gz` | 0.12 GiB each | 562 / 875 |

Every one of them fails the same way — the decompressor reaches the end of the object
before the archive ends — and every one of them shares a property worth recording:

**Their sizes are exact multiples of 4,096 bytes.** Of the 435 tested archives of 1 MiB or
more, 22 have a size that is an exact multiple of the filesystem block size, and all 22 are
in the table above. The other 413 are not block-aligned and not one of them failed a test.
That separation is complete in both directions, which is more than a coincidence would give
— a random size hits a 4 KiB boundary about once in 4,096, so 22 of 435 is four orders of
magnitude off chance.

The reading is that these files were truncated **while being written to the local disk**,
at the last block the filesystem could give out, and then uploaded intact. That makes them
the same failure as `tellerstec` with a different trigger: `tellerstec` was a compressor
killed by the watchdog, and these are writes that hit a full volume. The three
`server/2026-06-28/` objects are the strongest case, because this document already dates an
ENOSPC episode to 2026-06-28 — "a separate episode when DirectAdmin still staged backups in
`/tmp`" — and the `server/2026-06-29/` account archives are the migration uploading what
that episode had left on disk. That a killed write lands on a block boundary is **inferred**
from the arithmetic; that the objects are unreadable is observed, twice, by two independent
tests for the `.tar.gz` half.

The seven consecutive weeks of `custom/usr/local.tar.gz` are the part that is not explained
by a single bad night. From 2026-03-22 to 2026-06-28 that one member failed every week
while everything beside it in the same tree succeeded, and the 2024 instances are the same
handful of large members. `/usr/local` is the largest thing `sysbk` archives after the home
directories. Whether that is one recurring cause or a coincidence of the largest file
meeting a tight volume each week is **not established** here.

`--max-bytes` and `--prefix` on the script exist so this can be re-run cheaply: a
`--quick` pass over the whole `.tar.gz` half of the bucket costs cents and, on this
evidence, finds what a full read finds.

### What was done about them

Each of the 21 newly found objects has been renamed with a `.TRUNCATED-DO-NOT-RESTORE`
suffix, the same treatment `tellerstec` got on 2026-09-07, and **nothing was deleted**. A
fragment that lists 141,978 members before it stops is worth more than nothing for an
account with no other copy of that date, and it should not sit under a name someone could
mistake for a backup. The bucket's 365-day expiry removes them on its own.

S3 has no rename, so each was a server-side copy followed by a delete of the old key, with
the storage class carried across and both keys checked before and after. The bucket held
8,067 objects and 775,343,444,543 bytes before and after: 21 keys added, 21 removed, no
change in total. Two consequences worth stating. Renaming resets each object's lifecycle
clock, so the 365-day expiry now runs from 2026-09-08 rather than from the original upload
— a few months later than it would have been for the 2024 objects. And the `.md5` sidecars
`sysbk` wrote alongside the affected members now name a file that no longer exists under
that name, which is cosmetic but will look odd to anyone reading a manifest.

### What this changes, and what it does not

Readability is not the whole of restorability, and the distinction is worth keeping. What
is now established is that these objects are complete, well-formed archives holding
plausible account trees. What is **not** established is that DirectAdmin will ingest one
and produce a working account, or that the SQL dumps inside them load. That is still
unrehearsed, and it is the part a person has to do — see
[Still open](#still-open). The useful change is that a rehearsal can now start from an
archive known to be whole, so a failure would be attributable to the restore path rather
than to the backup.

## State of the host as of 2026-09-07 21:30 EDT

Merging the fixes in this repository does not change the host — there is no deploy
pipeline. The following was applied over SSM after #120 merged, and verified read-only
afterwards.

**The pipeline fix is live and matches what is now on `main` of the website repository.**
`store.py` and `ingest.py` under
`/home/tellerstec/public_html/wp-content/plugins/tellerstech-landing/oncallbrief-pipeline/`
hash `0dcf0b08…` and `9d4fa5cd…`, byte-identical to the files merged as
TellersTechOrg/tellerstech-website#1393, and `tests/test_dedupe_backlog.py` is present.
That directory is not a git checkout, so deploys there are manual copies; the merge
matters because the next manual copy now carries the fix instead of reverting it.

**The timer has not yet run the fixed code.** `oncallbrief.service` still records
`Result=oom-kill` from Sep 7 03:45 — the last time it fired, which was before the query
fix was deployed. The verification run that measured 667 MB was a separate transient unit,
so the scheduled path itself is unproven. Sep 8 03:45 EDT is the first timer run under the
fix; the things to check afterwards are `systemctl show oncallbrief.service -p Result`,
whether the healthcheck went green, and whether `sar -S` shows any swap at all around
03:45.

**The ops tooling was five commits stale, and two pieces had never been installed.** The
checkout at `/root/wbat-terraform` was at #112, which predates the backup hooks being
managed at all. `--verify` reported both hooks `STALE` and the disk guard, its cron entry,
and the logrotate config all `MISSING (never installed)`. Every P1 and P2 fixed across
#114 through #119 — the quiescence deferral, verified-before-delete, the recorded S3
destination sidecar, the `find` status checks — was sitting in git and not running. After
`git merge --ff-only origin/main` and `install_da_vhost_listen.sh --install`, `--verify`
passes on all eleven managed paths. Rollback copies of the previous hooks and of root's
crontab are in `/root/da-ops-rollback-20260907-212741/`.

**The disk guard works, and its first run was a true positive.** It reported `/` at 74%
with 52.4 GB free and inodes at 1%, then flagged swap: 17% in use at the time, but
**peaking at 74% at 03:50 today** — the moment the memory-capped pipeline run was
OOM-killed. It mailed `brianateller@gmail.com`. That alert should stop appearing once a
run completes without swapping; if it recurs after a clean run, something else is
thrashing.

**Step 4 above is done.** Root's crontab now reads `0 5 * * 6 /usr/local/sysbk/sysbk -q`
instead of `/usr/local/directadmin/shared/sysbk.sh -q`. The cron log makes the difference
unambiguous: the Aug 15, 22 and 29 runs of the old script each took about 22 minutes, and
`/backup/08-29-26` holds 5.6 GB of `custom/` and 1.9 GB of `mysql/` including a 1.08 GB
`full-mysql.tar.gz`. The Sep 5 run of the replacement started and ended in the same second
and produced a single 55 KB `sysbk-09-05-26.tar.zst` containing `/etc/nginx`, `/etc/httpd`,
`/var/named` and `/etc/named.conf`. Next run is Saturday 05:00; expect gigabytes and a
`mysql/` directory.

Worth being precise about why the replacement is empty rather than broken:
`/usr/local/directadmin/shared/sysbk.sh` *can* dump databases — it calls `mysqldump` — but
it sources `/usr/local/directadmin/data/admin/sysbk.conf`, and on this host that file
still contains legacy SysBK-1.0 configuration (`MYSQL_BK="1"`, `CUSTOM_BK="1"` and so on).
The variable names do not match what DirectAdmin's script reads, so it silently did the
handful of paths whose defaults happened to line up and skipped everything else.

**Admin backups have been failing every day for two months, silently.** This sharpens the
"newest backup is 2026-07-02" note below into something with a mechanism.
`/var/log/directadmin/system.log*` shows `Running Backup: type=admin owner=admin id=1` at
05:00 every single day from Aug 17 through Sep 7 without a gap, so the schedule is intact
and firing. But `/home/admin_backups` is empty and its own mtime is **Jul 2 05:52**, and
`/var/log/da-backup-s3.log` has not been written since the same minute. The engine is not
merely producing incomplete archives — it is not creating a file at all, and the hook has
had nothing to fire on since July. Nothing alerts on this: DirectAdmin logged no error,
raised no ticket, and the daily failure is invisible from the panel.

Do not simply re-enable or recreate the job. As the arithmetic in step 1 now shows, a
successful full run needs 66+ GiB of local staging against 60 GB free, so "fixing" the
trigger without first changing where the archives are written would fill the volume at
05:00 the next morning. `da_backup_batch.sh` above is that change; DirectAdmin's schedule
should be deleted rather than repaired.

**`/backup` is empty again, and 7.4 GB came back.** `09-05-26` and `08-29-26` were the
last two directories left there. Both were verified against S3 with
`rclone check --checksum --one-way` — 2 and 136 files respectively, zero differences —
and only then deleted. That was a weaker justification than it read at the time, for the
reason the `tellerstec` archive went on to demonstrate: a checksum match is a statement
about bytes, not about completeness. Both weeks have since been read back out of S3 and are
whole, so the decision stands on evidence rather than on the checksum alone. The volume
went from 74% to **71% used, 60 GB free**. Note that the
weekly `sysbk` run restored in step 4 writes roughly 7.4 GB every Saturday, and nothing
currently sweeps it: see the last point under "Still open".

**Eleven accounts now have a backup, and two still do not.** The supervised run at 22:15
EDT put 14.96 GiB across 11 objects into `server/2026-09-07/` — the first account backups
since 2026-07-02 — and failed on `tellerstec` in a way that put a truncated archive into
S3 before it was caught. Full account of it, and the measurements that came out of it, is
under [the first real run](#the-first-real-run-2026-09-07-2215-edt). The state left behind:

- `/home/admin_backups` empty, `/` at 71% used with 60 GB free, unchanged from before the
  run.
- The truncated object renamed to `…tar.zst.TRUNCATED-DO-NOT-RESTORE`.
- **Nothing scheduled, and nothing from #122 is on the host.** `/root/wbat-terraform` is
  still at #120, which is what the deploy above brought it to; `--verify` passing on
  eleven managed paths is a statement about #120's tooling, not this one's.
  `/etc/cron.d/da-backup-batch` is not installed, and the temporary copy of the script
  used for the supervised run has been removed from `/root`. The two fixes that came out
  of the run **have to be deployed together**: the batch script's watchdog writes
  `/run/da-backup-abort` before it signals anything, and it is `all_backups_post.sh` that
  reads the sentinel and refuses to upload. Install one without the other and a floor
  breach either publishes another fragment to S3 (batch without hook) or leaves a partial
  archive on disk with nothing to remove it (hook without batch). Once #122 merges:

  ```bash
  cd /root/wbat-terraform && git fetch origin && git merge --ff-only origin/main
  sudo ./scripts/directadmin/install_da_vhost_listen.sh --install
  ./scripts/directadmin/install_da_vhost_listen.sh --verify   # thirteen paths, not eleven
  ```

  `--install` is also what creates the 01:00 cron entry, so DirectAdmin's own schedule
  should be [deleted](#3-delete-directadmins-backup-schedule--this-one-needs-the-panel) in
  the same sitting. Until all of that happens, account backups are not happening on a
  schedule.
- `tellerstec` and `teller` have no current backup and will not get one from this tooling
  without more disk.

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

Archive integrity is a separate script, because it talks to S3 rather than to a host and
because its expensive mode costs real egress:

```bash
./aws/docs/verify-s3-archives.sh --self-test                       # offline, no credentials
./aws/docs/verify-s3-archives.sh --quick --prefix server/2026-     # cents, .tar.gz only
./aws/docs/verify-s3-archives.sh --full  --prefix server/2026-09-07/
```

It needs `s3:ListBucket` and `s3:GetObject` and exits non-zero if anything in the sweep
could not be read, so it can gate a restore decision. Results of the first run are
[above](#is-what-is-already-in-s3-readable-a-read-back-of-every-archive-2026-09-08).

## Still open

- **The kernel-side cause of the process kills** is unconfirmed. `dmesg` was never
  captured and journald is volatile here; enabling a persistent journal
  (`mkdir -p /var/log/journal && systemctl restart systemd-journald`) would make the next
  occurrence answerable.
- **No CloudWatch disk or memory alarm exists.** The only alarms in this account are the
  two billing alarms in [`billing-alarms.tf`](../global/cloudwatch/billing-alarms.tf).
  [`da_disk_guard.sh`](../../scripts/directadmin/da_disk_guard.sh), installed on the host
  on 2026-09-07, covers disk, inodes, and memory, but it is hourly cron on the host —
  exactly what a thrashing box cannot run. It reads `sar` history specifically so it can report a spike it slept
  through, but that is after the fact. An alarm that can page during the event needs the
  CloudWatch agent publishing `disk_used_percent` and `mem_used_percent`, plus
  `aws_cloudwatch_metric_alarm` resources beside the billing alarms.
- **`StatusCheckFailed_Instance` is already published and unalarmed.** It went to 1 for
  four and a half hours during this outage with no notification. That is a metric EC2
  emits for free, needs no agent, and would have caught this — the cheapest available
  improvement, and it belongs in Terraform.
- **The two largest accounts cannot be backed up on this volume.** `tellerstec` needs
  about 64 GiB of peak local space and `teller` about 87 GiB, against 59.8 GiB free, and
  the reason is DirectAdmin's own behaviour rather than anything schedulable — it holds
  the assembled parts of a backup and the archive built from them on disk at the same
  time. The other twelve accounts fit comfortably. Deciding this needs a person: a
  dedicated volume for `/home/admin_backups`, a bigger root volume (200 GB, 71% used), or
  a different mechanism for those two accounts. Measurements are under
  [the first real run](#the-first-real-run-2026-09-07-2215-edt).
- **Restore has never been rehearsed** — though the archives have now been read.
  [The 2026-09-08 sweep](#is-what-is-already-in-s3-readable-a-read-back-of-every-archive-2026-09-08)
  read every compressed object in the bucket and settled the readability half of this:
  the eleven 2026-09-07 account backups, the thirteen from 2026-07-02 and all ten weekly
  system backups are complete, well-formed archives holding plausible account trees, and
  22 older archives are not and have been renamed. What is still untested is whether
  DirectAdmin will ingest one of them and produce a working account, and whether the SQL
  dumps inside load. A rehearsal needs somewhere to restore *to*, which on this host means
  the same disk problem as everything else; the smallest useful version is one of the
  sub-megabyte accounts (`test2`, `brian2`, `aubrey`) into a scratch account. The change
  from before is that a rehearsal now starts from an archive known to be whole, so a
  failure would be attributable to the restore path rather than to the backup.
- **The sweep has no trigger yet, and gets one with #122.**
  `sweep_old_system_dirs` in `all_backups_post.sh` is what keeps `/backup` from
  accumulating, and the hook only runs when DirectAdmin fires a backup event. That is why
  the two directories left there on 2026-09-07 had to be verified and removed by hand. It
  is no longer true that no such event happens — the supervised batch run fired the hook
  twelve times — but nothing is *scheduled*, so nothing sweeps on its own today, while the
  weekly `sysbk` run restored in step 4 adds about 7.4 GB every Saturday. Installing
  `/etc/cron.d/da-backup-batch` fixes this as a side effect: each nightly run fires the
  hook, which uploads the week and then sweeps what it can confirm. Worth checking after
  the first Saturday that follows the deploy, because it is the first time that path runs
  against a directory it did not create.
- **`/usr/local/sbin/migrate-backups-to-s3.sh` and `verify-backups-s3.sh`** exist on the
  host, are not in this repository, and were not examined.
