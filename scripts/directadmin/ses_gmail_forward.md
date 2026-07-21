# DirectAdmin → Gmail via SES (keep MX on DirectAdmin)

Inbound mail stays on **DirectAdmin / Exim**. This pipe sends an authenticated
**copy** to Gmail through SES so you do not hit `554 Email address is not verified`
(that happens when Exim relays a forward through SES with the original From).

**Do not** point the domain MX at SES for this flow.

## Flow

```
Internet → MX DirectAdmin → local mailbox (Roundcube)
                         ↘ unseen pipe → ses-gmail-forward.py → SES → Gmail
```

SES `From` = allowlisted local address (verified domain). `Reply-To` = original sender.

## 1. Terraform / IAM (this repo)

Apply the AWS workspace so that:

- Instance role `WBAT_Main_Server` can `ses:SendRawEmail` and read the secret
- Secret `tellerstech/ses-gmail-forward/runtime-config` exists

## 2. Populate Secrets Manager

Edit `tellerstech/ses-gmail-forward/runtime-config` (values only in AWS, not git):

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

## 3. Install script on the mail server

```bash
install -m 755 scripts/directadmin/ses_gmail_forward.py \
  /usr/local/bin/ses-gmail-forward.py

mkdir -p /var/lib/ses-gmail-forward /var/log
touch /var/log/ses-gmail-forward.log
chmod 750 /var/lib/ses-gmail-forward
```

Needs Python 3 + `boto3` (or a venv) and the instance profile credentials.

```bash
python3 -c 'import boto3; print(boto3.__version__)'
# Optional smoke test (paste a tiny .eml on stdin):
# printf 'From: a@example.com\nDate: Tue, 21 Jul 2026 12:00:00 +0000\nSubject: t\n\nbody\n' \
#   | /usr/local/bin/ses-gmail-forward.py user1@example.com
```

## 4. Wire Exim / DirectAdmin (unseen pipe)

Deliver **locally as today**, and add an **unseen** pipe so the original is not
stolen by the pipe.

### Option A — Exim system filter (recommended pattern)

On the DA box, add a system filter snippet that pipes only after local routing
(exact path varies by DA/Exim layout). Conceptually:

```
# Pseudocode — adapt to your Exim system_filter / DA custom router docs.
# For each message where $local_part@$domain is allowlisted on the server,
# also run:
unseen pipe "/usr/local/bin/ses-gmail-forward.py ${local_part}@${domain}"
```

Because the script no-ops for non-allowlisted recipients, you may pipe all
local mail for the domain and keep the allowlist only in Secrets Manager.

### Option B — Per-address alias (local + pipe)

In the domain aliases file (DA virtual aliases), use a dual destination so
mail is saved **and** piped (syntax depends on Exim/DA version), e.g. concept:

```
localpart: localpart, |/usr/local/bin/ses-gmail-forward.py localpart@example.com
```

Confirm with a test that Roundcube still gets the message if the pipe fails
(script exits `0` on SES errors so Exim should not bounce local delivery).

### Remove broken Gmail forwarders

Delete DirectAdmin forwarders that pointed allowlisted addresses at Gmail via
the SES smart host (those caused the 554 unverified-From bounces).

## 5. Test

1. From an **external** account, mail an allowlisted address.
2. Confirm Roundcube has the message (MX still DA).
3. Confirm Gmail received the SES copy (`Reply-To` = original sender).
4. Check `/var/log/ses-gmail-forward.log`.

## 6. Leave SES inbound receive disabled

`enable_inbound_forwarding` should stay **false**. That stack receives mail at
SES MX and is the wrong model when DirectAdmin owns inbound.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Nothing in Gmail | Recipient not in secret allowlist; check log |
| `AccessDenied` on SES | Instance profile policy not applied / wrong role |
| `Email address is not verified` | Sending as an address/domain not verified in SES |
| Roundcube empty | Pipe replaced delivery instead of `unseen` — fix Exim/alias |
| Flood of SES sends | Rate limits in secret; check `/var/lib/ses-gmail-forward` |
