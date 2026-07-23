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

## Backup hooks (server install)

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
