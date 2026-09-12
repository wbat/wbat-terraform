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
  "max_message_bytes": 10485760,
  "reply_to_all": false,
  "via_labels": {
    "example.com": "HouseName",
    "second.example": "SecondName"
  }
}
```

`reply_to_all` and `via_labels` are both optional. See
[Recipients and replies](#recipients-and-replies) and
[Which domain a message came in on](#which-domain-a-message-came-in-on).

## Recipients and replies

The forwarded copy has to come **From** the allowlisted address, because that is the
identity SES has verified — the original `From` moves to `Reply-To` and
`X-Original-From`. Everything else about who the message was addressed to is left
intact:

| Header on the Gmail copy | Value |
|---|---|
| `From` | `Original Sender via example.com <user1@example.com>` (see `via_labels`) |
| `To` | your Gmail address **in place of** the allowlisted alias, plus every other original `To` |
| `Cc` | the original `Cc`, unchanged |
| `Reply-To` | the sender's own `Reply-To` if they set one, else their `From` |
| `X-Original-To` / `X-Original-Cc` / `X-Original-From` | the untouched originals |

Delivery is the SES **envelope** (`Destinations=[gmail_destination]`), never these
headers, so naming other recipients in `To`/`Cc` does not send them anything — it only
gives Gmail what it needs to compose a correct **Reply-All**. This is why the alias is
swapped for the Gmail address rather than added alongside it: Gmail drops your own
address from Reply-All, so leaving the alias in would bounce your reply back through
this pipe to yourself.

If the alias was only on `Cc`, the Gmail address lands on `Cc` too, so "cc me" does not
read as "to me".

Any **other** address in `recipients` is dropped from the visible headers for the same
reason: they all forward into the same Gmail inbox, so a message addressed to two of
your aliases would otherwise turn one Reply-All into another copy arriving back through
this pipe. `X-Original-To` still records that it was addressed to both.

An **SMTPUTF8** recipient (RFC 6531 — non-ASCII in the address itself, not just the
display name) cannot go in `To`/`Cc` at all: there is no ASCII form of one, and trying
to render it is what would otherwise raise inside the pipe and bounce a message
Roundcube already has. Those addresses are left out of `To`/`Cc`, kept in
`X-Original-To`/`X-Original-Cc` — unstructured headers, so an encoded word is legal
there — and logged:

```text
WARNING Omitted 1 non-ASCII (SMTPUTF8) recipient(s) from forwarded To/Cc: bj\xf6rn@…
```

## Which domain a message came in on

Several domains funnel into one Gmail inbox, and the forwarded `From` is always the
allowlisted address, so without a hint every message looks alike. Gmail shows the
display name and hides the address behind a click, so the `via …` suffix is the only
part of that visible at a glance:

```text
From: Brian Teller via example.com <user1@example.com>
From: Brian Teller via second.example <user1@second.example>
```

The default is the **domain of the address the mail arrived at**, which is never wrong.
`via_labels` maps a domain to a nicer house name; keys are matched case-insensitively,
and a domain that is not listed still falls back to itself rather than borrowing another
domain's label:

```bash
aws secretsmanager get-secret-value \
  --secret-id tellerstech/ses-gmail-forward/runtime-config \
  --query SecretString --output text | jq .          # current value
# then put back the same JSON with via_labels added:
aws secretsmanager put-secret-value \
  --secret-id tellerstech/ses-gmail-forward/runtime-config \
  --secret-string "$(jq -c '.via_labels = {"example.com":"HouseName"}' /tmp/cfg.json)"
```

The config is re-read at most every 60 seconds, so a label change takes effect on the
next message without touching the server. A malformed `via_labels` costs the nicer label
and nothing else — the forward still goes out with the domain.

### When a plain Reply should reach everyone

By default `Reply-To` is the sender alone, so **Reply** goes to the sender and
**Reply-All** goes to everyone — standard mail behaviour. Setting `"reply_to_all": true`
appends the other original `To`/`Cc` addresses to `Reply-To`, which makes a plain Reply
reach all of them. That is a footgun (there is then no way to reply to the sender only
without editing the recipient list by hand), so it is off unless you ask for it.

### The destination has to be the mailbox you read in

`gmail_destination` is the whole SES envelope, so it is also the only address Gmail sees
the message as addressed to. Point it at an account that auto-forwards onward and
Reply-All disappears in the account you actually read: the copy arrives with
`Delivered-To` set to the forwarding hop, the reading address is nowhere in `To`, and
Gmail offers Reply-All only when more than one participant is not you. Every recipient
is still in the headers — Gmail just stops offering to use them. Set the destination to
the mailbox you read and drop the auto-forward instead of chaining them.

That address is also the loop guard, and it keys on the message rather than the mailbox:
a copy is skipped as `from_gmail_dest` only when the destination address itself appears
in `From`, `Sender` or `Reply-To`. Under the [outbound setup](#gmail-outbound) below,
mail composed in the destination account leaves as your domain address, so it does *not*
trip the guard; sending as the plain Gmail address is what does. That difference is
invisible while composing, so test from an unrelated account, and when a copy goes
missing read the log for `from_gmail_dest` instead of assuming it.

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
`rate_limit`, `ses_error`, `config_error`, `missing_gmail_dest`, and
`unrenderable_recipient`.

| `reason=` | Meaning |
|---|---|
| `auto_submitted` | `Auto-Submitted` present and not `no` |
| `pipe_reentry` | `X-Ses-Gmail-Forward: 1` already set (this pipe; not generic `X-Forwarded-*`) |
| `from_gmail_dest` | From/Sender/Reply-To is the Gmail destination |
| `mailer_daemon` | From looks like mailer-daemon / postmaster |
| `unrenderable_recipient` | The allowlisted address is not ASCII, so SES has no verified identity to send as (alerts) |
| `rate_limit` | Per-recipient or global hourly cap |
| `ses_error` | `SendRawEmail` failed |
| `oversized` / `missing_headers` / `empty_payload` | Message rejected before SES |

`Precedence`, `List-Unsubscribe`, and `X-Auto-Response-Suppress` alone are **not**
skip reasons — newsletters and list mail commonly set them and should still reach Gmail.

Rate-limit counters increment **only after a successful** `SendRawEmail`, so SES
failures do not burn quota.

### Rate-limit counters and the pipe's uid

Exim runs this pipe as whichever user the delivery resolves to — `root`, `mail` and a
DirectAdmin account have all created counters on this host — so the counter files cannot
assume a single owner. A 0644 file written by one uid cannot be reopened for writing by
the next, which silently stopped the counter advancing and made the hourly caps
under-count. Counters are therefore written as a temp file renamed into place (needs
permission on the **directory**, not the file) and left mode 0666.

This is also why `/var/lib/ses-gmail-forward` is 0777. That is a deliberate trade-off,
not an oversight: any local account on the host can therefore edit a counter, which at
worst lets it suppress forwarding for an hour by setting one high. On a box with ~91 site
accounts that is worth knowing, but the alternative — a fixed uid for the pipe — is a
DirectAdmin/Exim change, and a local account with code execution has larger levers than
this. The directory is **not** sticky, which the rename depends on.

`Rate-limit state unwritable` in the log now alerts through the health check: the limiter
fails open, so nothing else would ever report that the control had stopped working.

### Why the pipe always exits 0

Exim reads a nonzero pipe exit — or anything on stdout/stderr — as delivery failure, and
bounces the message **even though Roundcube already accepted it**. So every path here
exits 0, including the ones nobody anticipated: an unhandled exception is logged at
`ERROR` and swallowed rather than allowed to become a traceback. That is not silence,
because `ERROR` is exactly what the health check greps for; it is loud toward us and
quiet toward Exim. Logging itself is also set not to report handler failures, since
those go to stderr too.

The cost of that safety is that a bug shows up as a Gmail copy that never arrives, not
as a bounce, so `/var/log/ses-gmail-forward.log` is the only place it is visible.

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

Then the case that a single-recipient test cannot show, because `Cc` was always
preserved and only `To` was being overwritten:

5. Send to the allowlisted address **and** a second `To` address you control  
6. In Gmail, **Reply-All** — the second address must be on the reply  

If Gmail offers no Reply-All at all, read the copy's `Delivered-To`: more than one line
means the destination is being auto-forwarded, which hides the button no matter how
correct the headers are (see
[The destination has to be the mailbox you read in](#the-destination-has-to-be-the-mailbox-you-read-in)).

The header rewrite is covered offline by
[`prove_ses_gmail_forward.py`](./prove_ses_gmail_forward.py) (no AWS, boto3 stubbed),
which also asserts SES is still handed `Destinations=[gmail_destination]` and nothing
else while those third-party addresses sit in the headers.
