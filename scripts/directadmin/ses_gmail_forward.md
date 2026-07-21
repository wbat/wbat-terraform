# DirectAdmin → Roundcube + Gmail via SES (canonical)

**Current production path.** MX stays on DirectAdmin. Do **not** point MX at SES.

```
Internet
  → MX DirectAdmin / Exim
  → virtual alias pipe: |/usr/local/bin/ses-gmail-forward.py
       ├─ dovecot-lda  → Maildir / Roundcube
       └─ SES SendRawEmail → personal Gmail (verified From + Reply-To original)
```

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

Re-check aliases after any Forwarders UI edit; DA may rewrite them.

## Server install / update

```bash
curl -fsSL -o /usr/local/bin/ses-gmail-forward.py \
  https://raw.githubusercontent.com/wbat/wbat-terraform/main/scripts/directadmin/ses_gmail_forward.py
chmod 755 /usr/local/bin/ses-gmail-forward.py

mkdir -p /var/lib/ses-gmail-forward
touch /var/log/ses-gmail-forward.log
chmod 666 /var/log/ses-gmail-forward.log
chmod 777 /var/lib/ses-gmail-forward

ls -la /usr/libexec/dovecot/dovecot-lda /usr/sbin/dovecot-lda 2>/dev/null
python3 -c 'import boto3; print(boto3.__version__)'
# Alma/Rocky: dnf install -y python3-boto3
```

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
