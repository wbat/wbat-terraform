# DirectAdmin → Gmail via SES (most seamless DA setup)

**Keep MX on DirectAdmin.** Use the normal **Forwarders** UI with a pipe.
Do not forward to a Gmail address through the SES SMTP smart host (that causes
`554 Email address is not verified`).

## What you do in DirectAdmin (ongoing)

For each mailbox that should also land in Gmail:

1. **E-Mail Accounts** — keep/create the account (Roundcube stays as today).
2. **Forwarders** → Create forwarder  
   - From: the local address (same as the mailbox)  
   - To: `| /usr/local/bin/ses-gmail-forward.py`  
     (leading pipe is required)
3. Confirm DA still delivers to the mailbox. After saving, check aliases:

```bash
grep -E '^(brian|bteller):' /etc/virtual/tellerstech.com/aliases
```

Bare `brian` in the alias is rewritten to `brian@server.wbat.net` and fails.
Use a backslash-qualified address so Exim delivers to the virtual mailbox
without re-aliasing (and keep the pipe):

```text
brian: \brian@tellerstech.com, "|/usr/local/bin/ses-gmail-forward.py"
bteller: \bteller@tellerstech.com, "|/usr/local/bin/ses-gmail-forward.py"
```

Apply with:

```bash
python3 <<'PY'
from pathlib import Path
path = Path("/etc/virtual/tellerstech.com/aliases")
lines = []
for line in path.read_text().splitlines():
    if line.startswith("brian:"):
        lines.append(r'brian: \brian@tellerstech.com, "|/usr/local/bin/ses-gmail-forward.py"')
    elif line.startswith("bteller:"):
        lines.append(r'bteller: \bteller@tellerstech.com, "|/usr/local/bin/ses-gmail-forward.py"')
    else:
        lines.append(line)
path.write_text("\n".join(lines) + "\n")
print(path.read_text())
PY
```

**Important:** Do not edit these forwarders again in the DA UI without re-checking
aliases — the UI may rewrite them to pipe-only or unqualified `brian`.

That is the whole day-to-day UX. Allowlist / Gmail destination live in AWS
Secrets Manager (not in git).

## Flow

```
Internet → MX DirectAdmin → mailbox (Roundcube)
                         ↘ DA Forwarder pipe → ses-gmail-forward.py → SES → Gmail
```

SES sends as the local allowlisted address; `Reply-To` is the original sender.

## One-time server setup

### 1. Terraform

Apply AWS workspace so `WBAT_Main_Server` can `ses:SendRawEmail` and read
`tellerstech/ses-gmail-forward/runtime-config`.

### 2. Secrets Manager

Populate `tellerstech/ses-gmail-forward/runtime-config`:

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

`recipients` must include every address you create a pipe forwarder for.

### 3. Install the pipe binary

```bash
install -m 755 scripts/directadmin/ses_gmail_forward.py \
  /usr/local/bin/ses-gmail-forward.py
mkdir -p /var/lib/ses-gmail-forward
touch /var/log/ses-gmail-forward.log
# Exim runs the pipe as the mail/DA user — must be group-writable.
chgrp mail /var/log/ses-gmail-forward.log /var/lib/ses-gmail-forward
chmod 665 /var/log/ses-gmail-forward.log
chmod 775 /var/lib/ses-gmail-forward
python3 -c 'import boto3; print(boto3.__version__)'
```

### 4. Remove broken Gmail address forwarders

Delete Forwarders whose destination was a Gmail address (SES smart-host path).

### 5. Test

1. External mail → allowlisted address  
2. Roundcube has it  
3. Gmail has the SES copy  
4. `/var/log/ses-gmail-forward.log` shows success  

## Why a small script is still required

DirectAdmin Forwarders only send to **addresses** or **pipes**. They cannot
call Lambda/HTTP. A pipe to this script is the DA-native way to reach SES’s
API (instance role) without changing MX.

Leave `enable_inbound_forwarding = false` (SES-as-MX is a different model).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Nothing in Gmail | Address missing from secret `recipients`; check log |
| Roundcube empty | Forwarder replaced mailbox delivery — keep local account + pipe |
| `AccessDenied` | Instance profile IAM not applied |
| `Email address is not verified` | Local From domain/address not verified in SES |
| Script not run | Forwarder missing leading `\|` or wrong path |
