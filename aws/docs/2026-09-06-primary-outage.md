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
df -h /                                       # a correct run writes GB; do this after step 2
/usr/local/sysbk/sysbk -q; echo "rc=$?"       # the reverted script, not shared/sysbk.sh
du -sh /backup/"$(date +%m-%d-%y)"            # config-only is ~55 KB; with databases, GB
ls /backup/"$(date +%m-%d-%y)"/               # expect a mysql/ directory
```

Run the script you reverted **to**, not the one you reverted **from**.
`/usr/local/directadmin/shared/sysbk.sh` is the replacement identified above as the thing
that produces the 55 KB config-only archive, so verifying with it reproduces the bug and
looks like the revert failed.

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
