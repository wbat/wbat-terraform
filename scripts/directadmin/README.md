# DirectAdmin operational scripts

## Mail → Gmail via SES (canonical)

Inbound MX stays on DirectAdmin. Keep the **Email Account** (Exim → Roundcube).
Pipe forwarder runs [`ses_gmail_forward.py`](./ses_gmail_forward.py) → **SES only**
(Gmail copy). Do not use dovecot-lda in the pipe (fails as user `mail`).

Full runbook: [`ses_gmail_forward.md`](./ses_gmail_forward.md).

Forwarder destination in DA UI:

```text
|/usr/local/bin/ses-gmail-forward.py
```

### Persist pipe aliases (DA Forwarders UI rewrite)

DA rewrites `/etc/virtual/<domain>/aliases` when Forwarders change. Prefer DA
**hooks** (immediate) over cron; optional cron is a safety net.

| File | Install path |
|------|----------------|
| `ensure_ses_gmail_aliases.sh` | `/usr/local/bin/ensure-ses-gmail-aliases.sh` |
| `managed-aliases.conf.example` | `/etc/ses-gmail-forward/managed-aliases.conf` (edit; mode 600) |
| `forwarder_create_post.sh` | `/usr/local/directadmin/scripts/custom/forwarder_create_post.sh` |
| `forwarder_delete_post.sh` | `/usr/local/directadmin/scripts/custom/forwarder_delete_post.sh` |

```bash
install -m 755 scripts/directadmin/ensure_ses_gmail_aliases.sh \
  /usr/local/bin/ensure-ses-gmail-aliases.sh
mkdir -p /etc/ses-gmail-forward
install -m 600 scripts/directadmin/managed-aliases.conf.example \
  /etc/ses-gmail-forward/managed-aliases.conf
# edit /etc/ses-gmail-forward/managed-aliases.conf — real domain + local-parts

install -m 700 scripts/directadmin/forwarder_create_post.sh \
  /usr/local/directadmin/scripts/custom/forwarder_create_post.sh
install -m 700 scripts/directadmin/forwarder_delete_post.sh \
  /usr/local/directadmin/scripts/custom/forwarder_delete_post.sh

/usr/local/bin/ensure-ses-gmail-aliases.sh
# optional safety net:
# echo '*/15 * * * * root /usr/local/bin/ensure-ses-gmail-aliases.sh' \
#   >/etc/cron.d/ses-gmail-aliases

# Health check (every 5m): self-heal aliases + flag recent forward ERROR
install -m 755 scripts/directadmin/ses_gmail_forward_health.sh \
  /usr/local/bin/ses-gmail-forward-health.sh
install -m 600 scripts/directadmin/health.conf.example \
  /etc/ses-gmail-forward/health.conf
# edit HEALTH_ALERT_TO if you want local mail alerts
echo '*/5 * * * * root /usr/local/bin/ses-gmail-forward-health.sh' \
  >/etc/cron.d/ses-gmail-forward-health
chmod 644 /etc/cron.d/ses-gmail-forward-health
```

## Vhost listen reconciler (Linked IP drift)

Keeps every domain's nginx `listen` on the address public traffic arrives on
(primary private IP after EIP NAT). Root-cause fix is DirectAdmin Linked IP with
`apply=yes`; the reconciler makes it self-healing after instance replacement.

Install on **both** DirectAdmin hosts (`server.wbat.net` and `server2.wbat.net`).

Change window: [`aws/docs/da-vhost-listen-change-window.md`](../../aws/docs/da-vhost-listen-change-window.md).
Known-bad fixture: [`aws/docs/fixtures/nginx-catchall-broken-2026-07-26/`](../../aws/docs/fixtures/nginx-catchall-broken-2026-07-26/).

| File | Install path |
|------|----------------|
| `da_vhost_listen_reconcile.sh` | `/usr/local/sbin/da-vhost-listen-reconcile.sh` |
| `nginx_vhost_listen_invariant.sh` | `/usr/local/sbin/nginx-vhost-listen-invariant.sh` |
| `da_vhost_listen_verify_deploy.sh` | `/usr/local/sbin/da-vhost-listen-verify-deploy.sh` (weekly deploy-drift check) |
| `vhost-listen.conf.example` | `/etc/da-vhost-listen/vhost-listen.conf` (edit; mode 600) |
| `cron.d-da-vhost-listen` | `/etc/cron.d/da-vhost-listen` (mode 644) |
| `da-vhost-listen-boot.service` | `/etc/systemd/system/da-vhost-listen-boot.service` |
| `user_httpd_write_post-da-vhost-listen-check.sh` | `/usr/local/directadmin/scripts/custom/user_httpd_write_post/da-vhost-listen-check.sh` (mode 700, `diradmin:diradmin`) |
| `update_post-da-vhost-listen.sh` | append/call from `/usr/local/directadmin/scripts/custom/update_post.sh` |
| `host_access_audit.sh` | `/usr/local/sbin/host-access-audit.sh` (on-demand, no cron; see [Host access posture](#host-access-posture-ssh-rate-limiting-2222)) |
| `install_da_vhost_listen.sh` | not installed; run from the checkout to install the rows above or check them for drift |

### Install / update (from a repo checkout on the box)

The `install` sources are paths **inside this git repo**. They are not under a user
home (e.g. `/home/tellerstec`). On the host:

```bash
# First time:
#   cd /root && git clone git@github.com:wbat/wbat-terraform.git
cd /root/wbat-terraform
git fetch origin && git checkout main && git pull

# Full install (or re-install wiring). Do NOT overwrite an edited
# /etc/da-vhost-listen/vhost-listen.conf with the example unless intentional.
install -m 755 scripts/directadmin/da_vhost_listen_reconcile.sh \
  /usr/local/sbin/da-vhost-listen-reconcile.sh
install -m 755 scripts/directadmin/nginx_vhost_listen_invariant.sh \
  /usr/local/sbin/nginx-vhost-listen-invariant.sh
mkdir -p /etc/da-vhost-listen /usr/local/directadmin/scripts/custom/user_httpd_write_post
if [[ ! -f /etc/da-vhost-listen/vhost-listen.conf ]]; then
  install -m 600 scripts/directadmin/vhost-listen.conf.example \
    /etc/da-vhost-listen/vhost-listen.conf
fi
# Edit /etc/da-vhost-listen/vhost-listen.conf per host (see below).

install -m 644 scripts/directadmin/cron.d-da-vhost-listen /etc/cron.d/da-vhost-listen
install -m 644 scripts/directadmin/da-vhost-listen-boot.service \
  /etc/systemd/system/da-vhost-listen-boot.service
systemctl daemon-reload && systemctl enable da-vhost-listen-boot.service

install -m 700 -o diradmin -g diradmin \
  scripts/directadmin/user_httpd_write_post-da-vhost-listen-check.sh \
  /usr/local/directadmin/scripts/custom/user_httpd_write_post/da-vhost-listen-check.sh

/usr/local/sbin/da-vhost-listen-reconcile.sh --check
```

**Script-only update** after a reconciler PR (config/cron already present):

```bash
cd /root/wbat-terraform && git pull
install -m 755 scripts/directadmin/da_vhost_listen_reconcile.sh \
  /usr/local/sbin/da-vhost-listen-reconcile.sh
install -m 755 scripts/directadmin/nginx_vhost_listen_invariant.sh \
  /usr/local/sbin/nginx-vhost-listen-invariant.sh
/usr/local/sbin/da-vhost-listen-reconcile.sh --check
```

### One-command install / drift check (preferred)

**There is no deploy pipeline in this repo.** Merging a reconciler PR does not change
what the host executes — the running copy only changes when someone re-runs `install`.
That has already bitten: two merged PRs altered reconciler behaviour while the host kept
executing the previous version. [`install_da_vhost_listen.sh`](install_da_vhost_listen.sh)
makes both halves one command each:

```bash
cd /root/wbat-terraform && git pull

# Report whether the installed copies match this checkout (safe, read-only).
./scripts/directadmin/install_da_vhost_listen.sh --verify

# Install or update everything, enable the boot unit, then re-verify.
sudo ./scripts/directadmin/install_da_vhost_listen.sh --install
```

`--verify` compares each installed file against the repo by SHA-256 **and compares its
permission mode**, reporting `ok`, `STALE`, `MODE <found> (expected <declared>)`, or
`MISSING`, and exiting non-zero on any drift — so "did this merge actually reach
production?" has a definite answer. The mode half matters as much as the content half: a
hook that is byte-identical to the repo but has lost its executable bit cannot be run by
DirectAdmin at all, so backups accumulate on local disk while a content-only check calls
the host clean. Its managed list covers **all** the DA tooling, not
just the reconciler: the S3 backup hooks, the disk guard, its cron entry, and the
logrotate config are included, so the weekly check below watches them too. `--install` is idempotent and **never overwrites**
`/etc/da-vhost-listen/vhost-listen.conf`, because that file holds host-specific values
(`EXPECTED_PUBLIC_IP`, `HEALTH_ALERT_TO`); it is only created from the example when
absent. The runtime conf is therefore presence-checked, not content-compared.

Run `--verify` after any merge that touches `scripts/directadmin/`, and on both hosts.

### Weekly deploy-drift check (so nobody has to remember)

`--verify` only helps when a human runs it, which is the same weakness that let the
previous drift persist. [`da_vhost_listen_verify_deploy.sh`](da_vhost_listen_verify_deploy.sh)
is the cron-driven version, installed to `/usr/local/sbin/` and fired weekly by
`/etc/cron.d/da-vhost-listen` (Mondays 06:17). It checks every link in the chain from
`main` to the file that actually runs:

1. **checkout vs `origin/main`** — the box is sitting on an old commit, so `--verify`
   passes while still being wrong relative to `main`. This counts as drift **only when
   the pending commits touch `scripts/directadmin/`**. `main` advances constantly for
   Terraform and docs, and alerting on that would be a guaranteed weekly false alarm
   that teaches everyone to ignore the mail; an unrelated lag is logged as a `NOTE` and
   does not affect the exit status.
2. **checkout working tree vs its own commits** — a hand-edited file in the checkout
   makes checks 1 and 3 agree with each other while what runs matches no commit at all,
   so "installed == checkout" stops being evidence about `main`. Modified tracked files
   are drift; untracked files are a `NOTE`, since the installer only ever copies the
   explicit `MANAGED` list.
3. **installed vs checkout** — somebody pulled but never re-ran `--install`. This is
   `install_da_vhost_listen.sh --verify`, invoked from the checkout.

On drift it writes the full report to `/var/log/da-vhost-listen.log` **and** mails
`HEALTH_ALERT_TO` from the same `/etc/da-vhost-listen/vhost-listen.conf` the reconciler
uses, then exits non-zero. The report is logged as well as mailed on purpose, because
alerting is itself something that can be broken, and every way it can break is reported
as an `ERROR` rather than swallowed:

- `HEALTH_ALERT_TO` unset, or an RFC 2606 placeholder like `you@example.com`
- no `mail` binary
- **`mail` present but the local MTA rejects the submission** — the log records
  `ERROR alert submission FAILED (mail rc=N)` with the MTA's own message. A bare
  `|| true` here would log `OK alert mailed` for a message that never left the host,
  which is the worst possible failure for the one notification path cron doesn't
  duplicate. The reconciler shares this behaviour, and additionally releases its
  cooldown stamp on a failed send so the next run retries instead of buying an hour of
  silence for an alert nobody received.

There is deliberately **no alert cooldown** — it runs weekly, and drift that persists
deserves one mail a week until someone runs `--install`. A failed `git fetch` degrades to
a `WARN` rather than a failure, so a network blip does not mask the offline half of the
check, and `NOTE`/`WARN` lines are still logged on otherwise-clean runs so a qualified
pass is not read as a clean bill of health.

Because cron has no `SSH_AUTH_SOCK`, check 1 needs root to reach GitHub without an agent.
Confirm it under a cron-like environment rather than interactively:

```bash
env -i HOME=/root SHELL=/bin/bash \
  PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin \
  /usr/local/sbin/da-vhost-listen-verify-deploy.sh; echo "exit=$?"
```

`WARN git fetch failed` there means root's GitHub auth depends on an agent, and check 1
is silently inert under cron until a passphrase-less read-only deploy key is in place.

Override paths for testing: `DA_VHOST_LISTEN_REPO` (default `/root/wbat-terraform`),
`DA_VHOST_LISTEN_REMOTE_REF` (default `origin/main`).

### Per-host `vhost-listen.conf`

| Host | `EXPECTED_PUBLIC_IP` | Typical arrival (auto if unset) | `ALLOWLIST_CATCHALL_HOSTS` (example) |
|------|----------------------|----------------------------------|--------------------------------------|
| `server.wbat.net` | `44.214.133.234` | `172.30.0.71` | `server.wbat.net wbat.net` |
| `server2.wbat.net` | `34.205.151.236` | `172.30.0.57` | `server2.wbat.net` |

Set `ENFORCE_REQUIRE_PUBLIC_IP` to the same EIP as `EXPECTED_PUBLIC_IP` on multi-host
installs so `--enforce` cannot run against the wrong box.

Bare reconciler invocations default to `--check`. Cron and the boot unit pass
`--enforce` deliberately. The `user_httpd_write_post` hook is `--check` only.

Offline proofs (from a laptop checkout, no box access needed):

```bash
./scripts/directadmin/prove_vhost_listen_detector.sh   # the reconciler's detector
./scripts/directadmin/prove_install_verify.sh          # the deploy-drift check itself
```

The second one exercises `--verify` in a sandbox through the `DA_VHOST_*` path overrides,
including the case a content-only check got wrong: an unchanged hook at mode `600` must be
reported as drift rather than `ok`.

---

## Backups to S3 (and the disk guard)

Install on **both** DirectAdmin servers (`server` and `server2`).

| File | DirectAdmin event |
|------|-------------------|
| `all_backups_post.sh` | After **Admin Backup** (archives + staging dirs under `/home/admin_backups`) |
| `system_backup_post.sh` | After **System Backup** (`apache/`, `bind/`, `custom/`, `mysql/` under `MM-DD-YY/`) |

The system backup root is **detected, not assumed**: DirectAdmin writes to `/backup` on the
primary and `/home/backup` on other builds, and a hardcoded path is invisible when wrong —
the hook cleans an empty directory and logs success. Override with `DA_BACKUP_SYSTEM_ROOT`
if a host uses neither.

Both upload to `s3://wbat-tellerstech-directadmin-backups-<account>/<hostname>/YYYY-MM-DD/` (e.g. `server/` or `server2/`) via rclone remote `s3backup`, then **delete the local copies that `rclone check` confirmed are in S3**.

This hook is the only thing keeping backups off a 200 GB root volume, so it is written to
fail safe in both directions: it never deletes a local copy it has not verified in S3, and
it never leaves a verified copy on disk. Age is not treated as evidence that a backup is
safe to delete — even the old-directory sweep checks S3 first, because on the primary the
directories it would have swept were the only copy. See
[`aws/docs/2026-09-06-primary-outage.md`](../../aws/docs/2026-09-06-primary-outage.md) for
what was actually broken on that host, and `prove_backup_cleanup.sh` for the nineteen
behaviours that are now pinned.

"Verified in S3" used to mean `rclone check --checksum` agreed with the local file, which
says nothing about whether that file is a whole archive. On 2026-09-07 it agreed about a
20 GiB `.tar.zst` whose compressor had been killed mid-stream, and the hook logged `OK
admin upload verified in S3` and deleted the local copy; reading it back gives `zstd:
premature end`. So each archive is now decompressed to `/dev/null` and its tar listed
before it is uploaded (`DA_BACKUP_VERIFY_ARCHIVES=0` turns that off). This costs a full
read of every archive and needs a decompressor for the format — without `zstd` installed
the check silently passes, which is why the proof suite refuses to run without it. An
archive that cannot be read is dropped from the upload list rather than failing the run,
so one bad archive does not cost the other accounts their backup; it is left on disk,
named in the alert, and the run exits non-zero. The hook also refuses to upload anything at
all while `DA_BACKUP_ABORT_SENTINEL` (default `/run/da-backup-abort`) exists — see
`da_backup_batch.sh` below for why that ordering matters.

`system_backup_post.sh` execs `all_backups_post.sh --event=system`, and that flag is load
bearing. The two DirectAdmin events run the same script, so without it a run cannot tell
whether the system directory it can see is finished or still being written — and the lock
does not help, because it serialises hook runs rather than the backup process producing the
files. The system event means DirectAdmin has said the write is complete, so that run
uploads and cleans immediately. Any other run waits until the directory has been untouched
for `DA_BACKUP_SYSTEM_QUIESCE_SEC` (default 900) before touching it, and logs a `NOTE
deferring` line when it declines. If you see those every run, check that both hooks were
installed from the same checkout: an old `system_backup_post.sh` without the flag makes
every system backup look in-progress, and it will sit on disk until the sweep reaches it.

Alerting: a run that ends with backups still on disk mails `HEALTH_ALERT_TO` from
`/etc/da-vhost-listen/vhost-listen.conf` — the same address the vhost tooling uses, so
there is one per host rather than two that can disagree. There is no cooldown: backups run
days apart, so every failed run gets its own mail.

`da_backup_batch.sh` is what actually starts admin backups now, because DirectAdmin's own
schedule cannot. DirectAdmin archives every account before the hook above gets a chance to
upload anything, so it needs the whole set staged locally at once — 66 GiB at the last full
run in July 2026, on a volume that has had less than that free ever since. Every nightly
run from then until 2026-09-07 logged `Running Backup` and produced no file, with nothing
saying so. The engine is fine; a single-account run finishes in seconds and the hook clears
it. It is the all-at-once staging that does not fit.

So this driver invokes `admin-backup --user=` one account at a time, smallest first, and
refuses to start the next until the hook has confirmed the previous archive is in S3 and
gone from disk. Peak local usage becomes the largest single account rather than the sum.
Two guards, because the estimate is the part most likely to be wrong: a pre-flight check
that the estimated peak plus `DA_BATCH_RESERVE_GB` fits in the free space that exists right
now, and a watchdog that kills the backup if free space crosses `DA_BATCH_FLOOR_GB`
mid-run. An account that never fits is skipped and mailed rather than attempted, because an
account with no backup is worth saying out loud.

The estimate is of the archive DirectAdmin will write, not of the disk the account
occupies, and those differ whenever an account excludes something. DirectAdmin reads
`/home/<account>/.backup_exclude_paths` and passes it as `--exclude-from` right after `-C
/home/<account>`, to both the inner `home.tar` and the outer account archive, so a path
listed there is in the home and not in the backup. Sizing from `du -sk /home/<account>` is
what keeps `tellerstec` skipped every night: 34 GB of home, 29 GB of it Installatron's own
copies of applications DirectAdmin is already archiving, and a 68 GB peak against 59.8 GB
free for an archive that would come in around 16 GB. So the estimator subtracts what the
exclusions match. `--list` shows it in an `EXCLUDED` column and the run log says `less N GB
excluded`, because an exclusion that took effect and one with a typo in it have to look
different from each other rather than both looking like a smaller number.

Every part of that is written to fail towards over-stating an account, since over-stating
costs a skip that arrives by mail with the account named in it, while under-stating starts
a backup on a volume that cannot hold it. It asks the DirectAdmin binary whether
`allow_backup_exclude_path` is on and treats a config dump that fails, or that does not
carry the key, exactly like a `0` — the documented default is `1`, but a default is an
assumption rather than a reading. An entry with a leading slash or a `..` in it subtracts
nothing, because neither can match an archive member name and DirectAdmin will back the
path up regardless; the leading slash is the usual way this file is got wrong and it is
otherwise silent. A **trailing slash** subtracts nothing for the same reason and is the
worst of the three, because it is the natural way to write a directory: the shell expands
`application_backups/` to the directory quite happily, while GNU tar 1.35 given `app/` in
an `--exclude-from` archives both `app/` and `app/file`, and given `app` archives neither.
So does an entry that resolves outside the home, and an excluded symlink,
which keeps the link out of the archive rather than the tree it points at. Overlapping
entries are measured in a single `du` run so `domains` and `domains/example.com` cannot
come off twice, and a `du` or a glob expansion that fails sizes the account from its whole
home rather than from a partial total. `DA_BATCH_HONOUR_EXCLUDES` forces the answer to
`1` or `0` if you would rather not have it decided by interrogation.

Two more, both of which exist because this file is the one input to the script that an
account holder owns and can rewrite between runs:

- **Hard-linked bytes are not credited.** `du` counts an inode once per run, so a file with
  one link under an excluded path and another under a path that is archived is counted once
  by each of the two `du` runs and subtracted in full — while tar, having skipped the
  excluded link, writes the whole file out under the one it kept. Deciding it exactly means
  walking the home for every link, so any file under the excluded paths with a link count
  above one is simply not taken off, and the log says how much that was. An account that
  wanted to could otherwise hide a volume's worth of data behind it.
- **The list must be a regular file, and a small one.** It is read after the batch lock is
  taken and before the per-account timeout starts, so a read that never returns stops every
  account, not one, and nothing mails until the next night's run finds a day-old lock. A
  FIFO satisfies `-e` and `-r` and then blocks forever; a symlink to `/dev/zero` returns NUL
  bytes without end; a symlink to an ordinary file elsewhere would have this script read,
  and log lines from, a file DirectAdmin never would. So a symlink or a non-regular file is
  refused, the read is bounded by `timeout` in case the path is swapped after the check, and
  anything over `DA_BATCH_EXCLUDE_MAX_BYTES` (64 KB) is refused whole rather than read to the
  limit — a cut-off last line is not a shorter list but a different one, and
  `domains/example.com/private` clipped to `domains` names a real directory.

Writing one, per account, owned by the account:

```bash
install -m 600 -o tellerstec -g tellerstec /dev/null \
  /home/tellerstec/.backup_exclude_paths
printf 'application_backups\n' >/home/tellerstec/.backup_exclude_paths
/usr/local/sbin/da-backup-batch.sh --list   # EXCLUDED must be non-empty for that account
```

Paths are **relative to the home, with no leading slash, no trailing slash and no
`/home/<account>` prefix**, one per line, globs allowed (`domains/*/awstats`, `*.zip`).
`--list` is how you find out whether DirectAdmin and this script agree that the entry means
anything.

The peak is the estimated archive taken `DA_BATCH_PEAK_COPIES_PCT` over, not the archive
itself, because DirectAdmin needs room for two copies. It assembles the account under
`<destination>/<user>/` — `backup/home.tar.zst`, then a `.sql` per database, then the
config files — and only then tars all of that into the final archive *in the same
directory*, so both exist at once. Measured on the primary: `wbatnet`, 10.50 GiB home,
6.72 GiB archive, 12.69 GiB peak. Comparing one archive against free space is what let the
first real run start `tellerstec` and hit the floor on it.

Killing the compressor is not enough on its own, either. DirectAdmin runs
`all_backups_post.sh` itself, from inside the `admin-backup` invocation, **including when
the archive step failed** — so the hook empties the staging directory before this script
gets control back, and on 2026-09-07 that is how a 20 GiB fragment reached S3, checksummed,
logged as verified, and deleted locally. Deleting the partial afterwards cannot fix an
ordering; the watchdog therefore writes `DA_BATCH_ABORT_SENTINEL` *before* it signals
anything, and the hook checks that file before it touches a thing. The two halves must be
installed together, and the script refuses to start if it cannot write the sentinel.

Every account run is also bounded by `DA_BATCH_ACCOUNT_TIMEOUT`. The floor only fires when
the volume is being consumed, and a backup can hang at constant free space — an `rclone`
inside the hook that stops making progress, DirectAdmin blocked on a database lock. A run
stuck there holds the batch lock, so every cron invocation after it exits quietly on the
lock and account backups stop for good with nothing mailing. Past the limit the process
group is terminated, the archive it left is deleted, and the run reports itself
incomplete.

The lock branch itself is the other half of that. A run that finds the lock taken still
exits quietly, which is the right answer to two runs overlapping by minutes and the wrong
one to a holder that never lets go — nothing else in the script runs, so the daily
schedule would report success every night while no account was backed up. The holder
records its start time in `${LOCK}.started`, and a run that finds one older than
`DA_BATCH_STALE_LOCK_SEC` mails instead of skipping.

A run that selects **no** account is a failure, not a run with nothing to do. The backup
loop reads from a generator, so an empty selection is a loop body that never executes, and
the summary would then find nothing failed and nothing skipped and exit 0 — a report of
success for a night on which nothing was backed up. A typo in `--user=` exits 2 naming the
account and what does exist; a users directory that has moved, been renamed, or is
unreadable to the user cron runs this as exits 1 and mails, because that one is silent and
hits every account at once.

```bash
/usr/local/sbin/da-backup-batch.sh --list      # accounts, sizes, what fits right now
/usr/local/sbin/da-backup-batch.sh --dry-run   # plan without invoking DirectAdmin
/usr/local/sbin/da-backup-batch.sh --user=teller
```

Once it is installed, delete DirectAdmin's own schedule at **Admin Level → Admin
Backup/Transfer → Schedule**, or the two race at 05:00.

| Threshold | Default | Override |
|---|---|---|
| Reserve left free after the estimated peak | 10 GB | `DA_BATCH_RESERVE_GB` |
| Hard floor that kills a running backup | 8 GB | `DA_BATCH_FLOOR_GB` |
| Estimated archive as a % of the home directory | 100% | `DA_BATCH_RATIO_PCT` |
| Subtract what `.backup_exclude_paths` excludes | `auto` (ask DirectAdmin) | `DA_BATCH_HONOUR_EXCLUDES` |
| Largest `.backup_exclude_paths` that will be read | 65536 bytes | `DA_BATCH_EXCLUDE_MAX_BYTES` |
| Timeout on reading it | 10s | `DA_BATCH_EXCLUDE_READ_TIMEOUT` |
| Peak disk as a % of that archive | 200% | `DA_BATCH_PEAK_COPIES_PCT` |
| Wait for the hook to clear the staging dir | 1800s | `DA_BATCH_DRAIN_TIMEOUT` |
| Hard limit on one account's archive run | 21600s | `DA_BATCH_ACCOUNT_TIMEOUT` |
| Grace between TERM and KILL when stopping one | 60s | `DA_BATCH_KILL_GRACE` |
| Lock age at which a holder is reported, not skipped | 86400s | `DA_BATCH_STALE_LOCK_SEC` |
| File that tells the hook a run was killed | `/run/da-backup-abort` | `DA_BATCH_ABORT_SENTINEL` |

`da_disk_guard.sh` is the separate hourly watch for the host's resources. Nothing else in
the account monitors disk or memory (the only CloudWatch alarms are on billing, and the
CloudWatch agent is not installed), so without it a filling volume or a nightly memory
spike is invisible until services fail. It checks space, **inodes**, and **memory**, and
rate-limits its alerts to one per 6h.

Memory needs the extra trick: the 2026-09-06 outage developed and ended inside a
ten-minute window, and a thrashing host cannot run cron at all. So the guard reads the
day's peak `%swpused` back out of `sar` as well as sampling `/proc/meminfo`, letting it
report a spike it slept through. It watches `Committed_AS` rather than just used memory,
because commit hit 118% of RAM+swap while `%memused` still read a survivable 82%.

| Threshold | Default | Override |
|---|---|---|
| Disk warning / critical | 85% / 92% | `DA_DISK_GUARD_WARN_PCT`, `DA_DISK_GUARD_CRIT_PCT` |
| Inodes | 85% | `DA_DISK_GUARD_INODE_PCT` |
| Swap (current or today's peak) | 60% | `DA_DISK_GUARD_SWAP_PCT` |
| Committed memory vs RAM+swap | 95% | `DA_DISK_GUARD_COMMIT_PCT` |

| File | Install path |
|------|----------------|
| `all_backups_post.sh` | `/usr/local/directadmin/scripts/custom/all_backups_post.sh` (mode 700) |
| `system_backup_post.sh` | `/usr/local/directadmin/scripts/custom/system_backup_post.sh` (mode 700) |
| `da_disk_guard.sh` | `/usr/local/sbin/da-disk-guard.sh` |
| `cron.d-da-disk-guard` | `/etc/cron.d/da-disk-guard` (mode 644) |
| `da_backup_batch.sh` | `/usr/local/sbin/da-backup-batch.sh` |
| `cron.d-da-backup-batch` | `/etc/cron.d/da-backup-batch` (mode 644) |
| `logrotate.d-da-ops` | `/etc/logrotate.d/da-ops` (mode 644) |

## Install / update backup hooks

These rows are part of `install_da_vhost_listen.sh`'s managed list, so the one-command
install and the weekly deploy-drift check cover them:

```bash
cd /root/wbat-terraform && git pull
./scripts/directadmin/install_da_vhost_listen.sh --verify   # read-only
sudo ./scripts/directadmin/install_da_vhost_listen.sh --install
```

They used to be installed by hand from this table, which meant nothing could answer "is
the hook that runs after tonight's backup the hook in `main`?" — and a stale copy here
fills the root volume rather than merely failing to self-heal.

Requires root rclone config at `/root/.config/rclone/rclone.conf` with `s3backup` remote and `no_check_bucket = true`.

`/home/admin_backups` must be mode **711** (`drwx--x--x`) so per-user backup staging dirs are reachable. If it is `700`, DirectAdmin logs `create_backup_domain_dir: ... did not exist` and backups produce nothing to upload.

On **server2**, also confirm `backup_crons.list` uses `when=cron` (not `when=now`) so the Wed 5:30 AM schedule keeps firing.

## S3 retention

Objects are **not** deleted immediately after upload. The bucket lifecycle (Terraform `s3-directadmin-backups.tf`) tiers to STANDARD_IA / GLACIER_IR and **expires at 365 days**.

## One-time catch-up (already on disk)

Safe to run any time, including on a nearly full volume: it uploads what is there,
verifies it, and deletes only the verified copies.

```bash
/usr/local/directadmin/scripts/custom/all_backups_post.sh; echo "rc=$?"
tail -40 /var/log/da-backup-s3.log
df -h /
/usr/local/sbin/da-disk-guard.sh --report   # top consumers, never alerts
```

## Offline proof (no box access needed)

```bash
./scripts/directadmin/prove_backup_cleanup.sh
./scripts/directadmin/prove_backup_batch.sh
```

Runs the real hook against a stubbed rclone and mail in a temp sandbox, asserting both
halves of fail-safe: a failed or unverifiable upload keeps the local copy and alerts, and
a verified upload is always followed by the matching delete. It also covers the case where
the delete itself fails — a read-only filesystem or an immutable file — which must exit
non-zero and mail rather than log "cleanup complete" over a backup still sitting on disk.
That applies to the old-directory sweep too: it is the path whose job is clearing a
backlog, so a sweep that silently fails to reclaim anything is the worst place to be quiet.

## Troubleshooting (backups)

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| S3 only has `hook-test.txt` or tiny files | `/home/admin_backups` is `700` | `chmod 711 /home/admin_backups` |
| `create_backup_domain_dir: ... did not exist` in `errortaskq.log` | Same permission issue | `chmod 711` and re-run backup from DA UI |
| Hook never runs for system backups | Missing `system_backup_post.sh` | Install both hook scripts (see above) |
| Nothing new in S3 after schedule | `backup_crons.list` has `when=now` | Set `when=cron` to match `server` |
| Upload works but local disk stays full | Stale hook installed | `install_da_vhost_listen.sh --verify`, then `--install` |
| `--verify` says `MODE 600 (expected 700)` | The hook is the right code but not executable, so DirectAdmin never runs it | `--install` resets the mode; check what stripped it (a manual `cp`, or an editor writing in place) |
| Log says `cleaned local ...` but the files are still there | Pre-2026-09-06 hook: cleanup resolved a different directory than the upload, or a hardcoded `SYSTEM_ROOT` that DirectAdmin does not write to | `--install` the current hook; see [the incident doc](../../aws/docs/2026-09-06-primary-outage.md) |
| `WARN keeping ... not present in <prefix>` | An old backup directory is **not** in S3, so the sweep kept it | Upload it, then delete by hand. Never `rm -rf` an unverified backup dir |
| `WARN system backups found under more than one root` | Both `/backup` and `/home/backup` hold dated dirs | Only one is cleaned per run, and this now mails as well as logs. Consolidate them or pin `DA_BACKUP_SYSTEM_ROOT` |
| `NOTE deferring <dir>` on every run | `system_backup_post.sh` is missing or predates `--event=system`, so no run is ever the completion signal | `--verify`, then `--install`. Until then the directory waits for the sweep |
| `ERROR could not enumerate` / `could not list old directories` | `find` hit an unreadable subtree or an I/O error, so the file list was incomplete | Deliberate refusal to act on a partial list. Check permissions and `dmesg` for the underlying error |
| `backlog scan skipped: could not create a temp file` | `mktemp` failed, so the old-directory sweep never ran | Usually `/tmp` out of space or inodes, or mounted read-only — the same volume this hook exists to keep clear. `df -h /tmp`, `df -i /tmp`, `mount \| grep /tmp` |
| A stray `MM-DD-YY.s3dest` file under the backup root | A verified upload recorded its S3 destination and the local delete then failed | Expected, and deliberately left: the sweep reads it so a backup uploaded after midnight is verified against the prefix it actually went to, not the one its name implies. Removed automatically when the directory is finally reclaimed |
| Backups stop with no hook log at all | The DirectAdmin backup task itself is failing, so no post-hook fires | `grep 'dataskq.*backup' /var/log/messages`; a `Not implemented` error is a DA problem, not a hook problem |
| `ERROR ... not verified in S3 (rclone check rc=N)` | Objects did not land, or the bucket is unreachable | Local copies were kept deliberately; fix rclone/S3 access and re-run the hook |
| `backup local cleanup FAILED` / `ERROR could not remove N verified file(s)` | The upload was verified but the delete failed: read-only filesystem, `chattr +i`, or an I/O error | The copies named in the mail are already in S3 and safe to `rm` by hand; then find what blocked the delete (`mount | grep ' / '`, `lsattr`, `dmesg`) |
| `NOTE ignoring '...' ... a leading slash matches no archive member` | An entry in `.backup_exclude_paths` is absolute, so DirectAdmin excludes nothing for it | Rewrite it relative to the home (`application_backups`, not `/home/tellerstec/application_backups`) and re-check with `--list` |
| An account is skipped and `--list` shows `-` under `EXCLUDED` | Either there is no `.backup_exclude_paths`, or nothing in it resolves to anything inside the home | The log has a `NOTE ignoring` line per rejected entry saying which it is |
| `NOTE ... is not being taken off the size estimate ... not known to honour it` | `allow_backup_exclude_path` is `0`, or the config could not be read | `/usr/local/directadmin/directadmin c \| grep allow_backup_exclude_path`. Exclusions are deliberately ignored unless that reads `1`, because assuming otherwise under-states an account and fills the volume |
| `WARN could not measure the paths excluded by ...` | `du` failed part way through an excluded path | The account is sized from its whole home for that run, which can only cost it a skip. Check permissions and `dmesg` |
| `NOTE ignoring '...' ... a trailing slash matches no archive member` | An entry is written `application_backups/`, which the shell resolves and tar ignores | Drop the slash. The message names the spelling to use |
| `NOTE N KB ... is hard-linked and may still be reachable` | Something under the excluded paths has a link count above one, so those bytes may survive into the archive under a path that is not excluded | Expected when an account hard-links across the boundary, and deliberately not credited. `find /home/<account>/<excluded> -type f -links +1` shows which files |
| `WARN ... is not a regular file; sizing ... rather than opening it` | `.backup_exclude_paths` is a symlink, FIFO, or device | `ls -l` it. This is refused because a FIFO there blocks the read inside the batch lock and stops every account, so it is worth understanding how it got there |
| `WARN ... is N bytes, over the ... byte limit` | The exclusion list is larger than `DA_BATCH_EXCLUDE_MAX_BYTES` | Refused whole rather than truncated, because a cut-off final entry can name a directory much larger than the one intended. Shorten it, or raise the limit if it is genuinely that long |
| `ERROR another run held /var/log/... lock` | Admin and system backups overlapped and one waited out `DA_BACKUP_LOCK_WAIT` | `pgrep -a rclone`; clear the stuck upload, then re-run the hook |
| Disk fills with no backups in `/home` | Not the backup hook | `da-disk-guard.sh --report` for the actual consumers |

## Host access posture (SSH, rate limiting, 2222)

The DirectAdmin account names on this host are permanently public: this repo's git
history holds a verbatim `nginx -T` capture. Names cannot be un-published, so the
control is making them useless — key-only SSH, a fail2ban that demonstrably bans, and
a 2222 that is not open to the internet.

| Repo file | Install path |
|-----------|--------------|
| `host_access_audit.sh` | `/usr/local/sbin/host-access-audit.sh` |

Installed and drift-checked by
[`install_da_vhost_listen.sh`](install_da_vhost_listen.sh) along with the rest of
the host tooling, so it does not need to be copied by hand and `--verify` will
say when the installed copy predates the checks it is trusted to make:

```bash
cd /root/wbat-terraform && git pull
sudo ./scripts/directadmin/install_da_vhost_listen.sh --install

sudo /usr/local/sbin/host-access-audit.sh          # read-only posture report
sudo /usr/local/sbin/host-access-audit.sh --json   # same, for automation
```

Read-only by design: no config edits, no service restarts, no firewall changes.

Exit 0 means the audit was complete *and* found nothing; 1 means at least one
finding; 3 means it found nothing but could not run every check. Root is needed for
the interesting checks (`sshd -T`, `fail2ban-client`, `directadmin.conf`), so an
unprivileged run reports `SKIP` for those, counts them, prints `INCOMPLETE` and
exits 3 — otherwise automation could accept a posture that was never inspected.

Where a clean verdict would be easy but wrong, it does the harder thing:

- Bare `sshd -T` prints the base config only, so a `Match User` block that
  re-enables passwords is invisible to it. The audit re-resolves the config per
  connection context with `sshd -T -C` and names the account, and says plainly that
  address-keyed `Match` blocks cannot be exhausted by probing.
- Rate limiting is judged by whether *something* limits it. CSF's lfd and fail2ban
  are alternatives, and a DirectAdmin box normally ships lfd; demanding fail2ban would
  push an operator into running two iptables managers that undo each other's bans.
  Whichever is present is then checked by value — an `LF_DIRECTADMIN=0` is a service
  nobody is watching, and fail2ban is judged per jail, since a busy sshd jail would
  otherwise carry a summed ban count well clear of zero and vouch for a mail jail
  watching a logpath that does not exist on this build.
- Bound ports are judged against CSF's `TCP_IN` rather than just listed. A datastore
  on `0.0.0.0` is a finding — nothing rate-limits MySQL, and a success there is the
  whole dataset — and "reachable now" is separated from "firewalled until CSF stops".
- DirectAdmin settings are read by value. `brute_force_log_scanner=0` is a key that
  is present and a scanner that is off.
- The 2222 boundary is the security group, which is invisible from inside the
  instance. The audit reports the socket-level fact, then asks EC2 who is actually
  allowed in — so a panel already closed at the security group clears, instead of
  warning forever about a finding that has been fixed. That question is asked in a
  way that cannot answer "closed" by accident: the filter matches IPv6 ranges,
  prefix lists and group references as well as IPv4, and matches port *ranges*
  containing 2222 and `-1` all-traffic rules, which carry no `FromPort`. A call
  that fails is a skip, never an empty rule set, because a denied
  `DescribeSecurityGroups` read as "no rule allows 2222" is an all-clear on the
  most important question here.
- A running `amazon-ssm-agent` is reported as a running process, not as a recovery
  path. Only `PingStatus: Online` from the control plane means a session can
  actually be opened, and that is a separate check.

Remediation, with the ordering and rollback that keeps an SSM session as the way back
in, is in [aws/docs/host-access-hardening.md](../../aws/docs/host-access-hardening.md).

### Offline proof

```bash
./scripts/directadmin/prove_host_access_audit.sh
```

Twenty-one cases, every one of them a way this audit can mislead: a password path left
open while the report reads green, or a false alarm that sends an operator to install
something harmful. The motivating case is `PasswordAuthentication no` with PAM
keyboard-interactive still enabled: what most hardening checklists stop short of,
and it leaves the box brute-forceable while the config reads as hardened. The rest
cover `Match` blocks, skips that must not read as passes, settings that are present
but disabled, one fail2ban jail masking another, CSF/lfd counting as the rate limiter
it is, and MySQL bound to every interface.

Case 20 exists because of a gap the other cases created. Every security-group case
injected rules through `HOST_AUDIT_SG_RULES_FILE`, which proved the classification
and never once ran the JMESPath — and the JMESPath was wrong, missing the flatten
after the filter, so against real AWS output it returned nothing for a world-open
group and the check called an open panel closed. A test hook that bypasses the thing
most likely to be wrong is worse than no test, because it reports success. So the
query is stored in one variable, `DA_PANEL_SG_QUERY`, and Case 20 extracts that exact
string from the script and evaluates it with the same engine the AWS CLI uses against
recorded `describe-security-groups` shapes. Reverting the query to the old one fails
seven of its eight assertions; the eighth is the genuinely-closed group, which is
empty either way, and that is precisely why the bug was invisible.
