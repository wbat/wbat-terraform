# DirectAdmin → Roundcube + Gmail via SES (canonical)

**Current production path.** MX stays on DirectAdmin. Do **not** point MX at SES.

```
Internet
  → MX DirectAdmin / Exim
       ├─ Email Account → virtual_mailbox (LMTP) → Maildir / Roundcube
       └─ Forwarder pipe → ses-gmail-forward.py → SES → Gmail
            (verified From + Reply-To original)
```

**Critical:** Keep the **Email Account** in DA. Exim delivers Roundcube that way.
The pipe runs as user `mail` and **must not** call `dovecot-lda` (Maildir is `0700`
owned by the DA user → lda rc=75 → Exim bounce). The pipe only sends the SES copy
and **always exits 0**.

Outbound “Send mail as” from Gmail uses **SES SMTP** (`email-smtp.us-east-1.amazonaws.com:587`) with SES SMTP IAM credentials — separate from this inbound pipe.

## Terraform (already applied)

| Resource | Purpose |
|---|---|
| Secret `tellerstech/ses-gmail-forward/runtime-config` | Allowlist + Gmail destination + rate limits |
| IAM role policy `SesGmailForward` on `WBAT_Main_Server` | `ses:SendRawEmail` + read that secret |

See outputs `ses_da_gmail_forward_secret_name` / `_arn`.

## Secrets Manager shape (no real addresses in git)

```json
{
  "gmail_destination": "your-gmail@example.com",
  "recipients": [
    "user1@example.com",
    "user2@example.com"
  ],
  "rate_limit_per_recipient_per_hour": 30,
  "rate_limit_global_per_hour": 100,
  "max_message_bytes": 10485760
}
```

## DirectAdmin

1. Keep **Email Accounts** for each allowlisted address (Maildir for Roundcube).
2. **Forwarders** destination (exact):

```text
|/usr/local/bin/ses-gmail-forward.py
```

3. Aliases must be **pipe-only** (this is required on our Exim/DA):

```bash
grep -E '^(user1|user2):' /etc/virtual/example.com/aliases
```

```text
user1: "|/usr/local/bin/ses-gmail-forward.py"
user2: "|/usr/local/bin/ses-gmail-forward.py"
```

Do **not** use bare `user` or `\user@domain` in the alias — those fail on this host
(`user@serverhostname` or LMTP `501 Invalid character in localpart`).

### Persist against Forwarders UI rewrites

Aliases are **not** DA templates — there is no `templates/custom` override for them.
Use DirectAdmin’s email hooks + a desired-state file (preferred) and optional cron:

1. Config: `/etc/ses-gmail-forward/managed-aliases.conf` (from `managed-aliases.conf.example`)
2. Enforcer: `/usr/local/bin/ensure-ses-gmail-aliases.sh`
3. Hooks: `forwarder_create_post.sh` / `forwarder_delete_post.sh` under
   `/usr/local/directadmin/scripts/custom/`
4. Optional: cron every 15 minutes calling the enforcer

See [`README.md`](./README.md) install block. Log: `/var/log/ses-gmail-forward-aliases.log`.

## Server install / update

```bash
curl -fsSL -o /usr/local/bin/ses-gmail-forward.py \
  https://raw.githubusercontent.com/wbat/wbat-terraform/main/scripts/directadmin/ses_gmail_forward.py
chmod 755 /usr/local/bin/ses-gmail-forward.py

mkdir -p /var/lib/ses-gmail-forward
touch /var/log/ses-gmail-forward.log
chmod 666 /var/log/ses-gmail-forward.log
chmod 777 /var/lib/ses-gmail-forward

python3 -c 'import boto3; print(boto3.__version__)'
# Alma/Rocky: dnf install -y python3-boto3

# Health check (self-heal aliases + alert on recent ERROR / silent SES skips)
curl -fsSL -o /usr/local/bin/ses-gmail-forward-health.sh \
  https://raw.githubusercontent.com/wbat/wbat-terraform/main/scripts/directadmin/ses_gmail_forward_health.sh
chmod 755 /usr/local/bin/ses-gmail-forward-health.sh
install -m 600 scripts/directadmin/health.conf.example \
  /etc/ses-gmail-forward/health.conf  # or curl the example; set HEALTH_ALERT_TO
echo '*/5 * * * * root /usr/local/bin/ses-gmail-forward-health.sh' \
  >/etc/cron.d/ses-gmail-forward-health
chmod 644 /etc/cron.d/ses-gmail-forward-health
```

After merging pipe/health changes, re-copy both scripts to `/usr/local/bin/` on the
server (`install -m 755 …`). No service restart is required for the pipe.

## Skip guards (pipe → SES)

Before `SendRawEmail`, the pipe logs `WARNING skip_ses reason=…` and exits 0
(Roundcube already has the message via Exim). Health alerts on
`rate_limit`, `ses_error`, `config_error`, and `missing_gmail_dest`.

| `reason=` | Meaning |
|---|---|
| `auto_submitted` | `Auto-Submitted` present and not `no` |
| `auto_response_suppress` | `X-Auto-Response-Suppress` present |
| `precedence` | `Precedence: bulk\|list\|junk` |
| `pipe_reentry` | `X-Forwarded-For` / `X-Forwarded-To` already set (this pipe) |
| `from_gmail_dest` | From/Sender/Reply-To is the Gmail destination |
| `mailer_daemon` | From looks like mailer-daemon / postmaster |
| `rate_limit` | Per-recipient or global hourly cap |
| `ses_error` | `SendRawEmail` failed |
| `oversized` / `missing_headers` / `empty_payload` | Message rejected before SES |

`List-Unsubscribe` alone is **not** a skip reason (newsletters are legitimate).

Rate-limit counters increment **only after a successful** `SendRawEmail`, so SES
failures do not burn quota.

## Gmail (outbound)

| Setting | Value |
|---|---|
| SMTP server | `email-smtp.us-east-1.amazonaws.com` |
| Port | `587` + TLS |
| Auth | SES SMTP username/password |
| Treat as alias | Yes (for your domain addresses) |
| Default Send mail as | Domain address (e.g. `user1@example.com`) |
| When replying | Always reply from default address |

Profile photo for `@example.com` From in Gmail recipients is limited without Google Workspace.

## What not to do

- Do not set MX to `inbound-smtp.*.amazonaws.com` for this domain.
- Do not merge/apply the abandoned “SES Inbound” TFC variable set (PR #78) unless deliberately rebuilding SES-as-MX.
- Do not forward to a Gmail address through Exim’s SES smart host (causes `554 Email address is not verified`).

## Test

1. External sender → allowlisted address  
2. Roundcube has the message  
3. Gmail has the SES copy (`Reply-To` = original sender)  
4. `tail -30 /var/log/ses-gmail-forward.log` — no Mailer-Daemon bounce  
