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
| `vhost-listen.conf.example` | `/etc/da-vhost-listen/vhost-listen.conf` (edit; mode 600) |
| `cron.d-da-vhost-listen` | `/etc/cron.d/da-vhost-listen` (mode 644) |
| `da-vhost-listen-boot.service` | `/etc/systemd/system/da-vhost-listen-boot.service` |
| `user_httpd_write_post-da-vhost-listen-check.sh` | `/usr/local/directadmin/scripts/custom/user_httpd_write_post/da-vhost-listen-check.sh` (mode 700, `diradmin:diradmin`) |
| `update_post-da-vhost-listen.sh` | append/call from `/usr/local/directadmin/scripts/custom/update_post.sh` |
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

`--verify` compares each installed file against the repo by SHA-256 and reports `ok`,
`STALE`, or `MISSING`, exiting non-zero on any drift — so "did this merge actually reach
production?" has a definite answer. `--install` is idempotent and **never overwrites**
`/etc/da-vhost-listen/vhost-listen.conf`, because that file holds host-specific values
(`EXPECTED_PUBLIC_IP`, `HEALTH_ALERT_TO`); it is only created from the example when
absent. The runtime conf is therefore presence-checked, not content-compared.

Run `--verify` after any merge that touches `scripts/directadmin/`, and on both hosts.

### Per-host `vhost-listen.conf`

| Host | `EXPECTED_PUBLIC_IP` | Typical arrival (auto if unset) | `ALLOWLIST_CATCHALL_HOSTS` (example) |
|------|----------------------|----------------------------------|--------------------------------------|
| `server.wbat.net` | `44.214.133.234` | `172.30.0.71` | `server.wbat.net wbat.net` |
| `server2.wbat.net` | `34.205.151.236` | `172.30.0.57` | `server2.wbat.net` |

Set `ENFORCE_REQUIRE_PUBLIC_IP` to the same EIP as `EXPECTED_PUBLIC_IP` on multi-host
installs so `--enforce` cannot run against the wrong box.

Bare reconciler invocations default to `--check`. Cron and the boot unit pass
`--enforce` deliberately. The `user_httpd_write_post` hook is `--check` only.

Offline detector proof (from a laptop checkout, no box access needed):

```bash
./scripts/directadmin/prove_vhost_listen_detector.sh
```

---

Install on **both** DirectAdmin servers (`server` and `server2`) under `/usr/local/directadmin/scripts/custom/`.

| File | DirectAdmin event |
|------|-------------------|
| `all_backups_post.sh` | After **Admin Backup** (`.tar.zst` or `.tar.gz` under `/home/admin_backups`) |
| `system_backup_post.sh` | After **System Backup** (`apache/`, `bind/`, `custom/`, `mysql/` under `/home/backup/MM-DD-YY/`) |

Both upload to `s3://wbat-tellerstech-directadmin-backups-<account>/<hostname>/YYYY-MM-DD/` (e.g. `server/` or `server2/`) via rclone remote `s3backup`, then **delete local copies** after a successful upload.

## Install / update backup hooks

```bash
install -m 700 scripts/directadmin/all_backups_post.sh \
  /usr/local/directadmin/scripts/custom/all_backups_post.sh
install -m 700 scripts/directadmin/system_backup_post.sh \
  /usr/local/directadmin/scripts/custom/system_backup_post.sh
```

Requires root rclone config at `/root/.config/rclone/rclone.conf` with `s3backup` remote and `no_check_bucket = true`.

`/home/admin_backups` must be mode **711** (`drwx--x--x`) so per-user backup staging dirs are reachable. If it is `700`, DirectAdmin logs `create_backup_domain_dir: ... did not exist` and backups produce nothing to upload.

On **server2**, also confirm `backup_crons.list` uses `when=cron` (not `when=now`) so the Wed 5:30 AM schedule keeps firing.

## S3 retention

Objects are **not** deleted immediately after upload. The bucket lifecycle (Terraform `s3-directadmin-backups.tf`) tiers to STANDARD_IA / GLACIER_IR and **expires at 365 days**.

## One-time catch-up (already on disk)

```bash
/usr/local/directadmin/scripts/custom/all_backups_post.sh
tail -30 /var/log/da-backup-s3.log
df -h /
```

## Troubleshooting (backups)

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| S3 only has `hook-test.txt` or tiny files | `/home/admin_backups` is `700` | `chmod 711 /home/admin_backups` |
| `create_backup_domain_dir: ... did not exist` in `errortaskq.log` | Same permission issue | `chmod 711` and re-run backup from DA UI |
| Hook never runs for system backups | Missing `system_backup_post.sh` | Install both hook scripts (see above) |
| Nothing new in S3 after schedule | `backup_crons.list` has `when=now` | Set `when=cron` to match `server` |
| Upload works but local disk stays full | Old stub hook (no cleanup) | Deploy current `all_backups_post.sh` from this repo |
