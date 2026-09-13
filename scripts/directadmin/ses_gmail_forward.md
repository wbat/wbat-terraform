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

### The spam verdict stays on this server

Every `X-Spam-*` header SpamAssassin added is stripped from the copy. Those describe our
own scan of the inbound message, which is of no use to Gmail — it filters the copy itself
— and `X-Spam-Report` additionally names the scanning host and quotes whatever blocklist
notices the scan hit.

The reason it matters beyond tidiness is that scanning is **per domain**, set in
`/etc/virtual/<domain>/filter.conf`. A domain with it on produced a visibly different
copy from a domain with it off, for the same message from the same sender, which is a
difference no one reading the two copies can explain. Nothing is lost by dropping them:
the Roundcube copy of the original still carries the full report, which is where you
would go to ask why something scored what it did.

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

### Only put the pipe on addresses that are in `recipients`

An address whose alias carries the pipe but which is missing from the `recipients`
allowlist is declined: no Gmail copy, and the decline is `logger.info` rather than a
`skip_ses` reason, so nothing alerts on it by itself. Whether that also *loses* the
message turns on one thing — whether the local-part has a mailbox. DA's `virtual_forwarder`
router decides it:

```text
# pass a copy of the email to the next 'virtual_mailbox' router if this address is also a mailbox
unseen = ${if and {                                                                              \
             {exists{/etc/virtual/${domain_data}/passwd}}                                        \
             {bool {${lookup {$local_part} lsearch {/etc/virtual/${domain_data}/passwd} {yes}}}} \
             {!eq                                                                                \
                 {${lookup {$local_part} lsearch {/etc/virtual/$domain_data/aliases}}}           \
                 {$local_part}                                                                   \
             }                                                                                   \
         }{yes}{no}}
```

An `unseen` redirect lets routing continue, so with a mailbox the Maildir gets a copy as
well as the pipe — which is exactly why Roundcube has the message even when the pipe skips
(see [Skip guards](#skip-guards-pipe--ses)). Confirm per address rather than assuming:

```bash
exim -bt user1@example.com    # expect both virtual_address_pipe and dovecot_lmtp_udp
```

So there are two cases, and only one is an emergency:

| Piped, not allowlisted | Mailbox? | Result |
|---|---|---|
| yes | yes | No Gmail copy; message still delivered and readable in Roundcube |
| yes | **no** | The pipe is the whole delivery, so the message is **discarded** — no SES copy, no Maildir copy, and no bounce, because the pipe always exits 0 |

The second row is the worst failure this pipe has, and it is reached by adding a forwarder
in the DA UI for a local-part that has no mailbox. Health check 6 fails only on that row
(`pipe_alias_no_mailbox:<address>`) and logs the first as a `NOTE`, so the one alert it can
raise always means lost mail.

Audit this per **address**, not per domain. `grep -l` prints only the filename, so a
stale local-part sitting beside two good ones reports the domain as covered and the stale
address goes on quietly discarding mail. Compare full addresses instead:

```bash
pipe_addrs() {
  # A domain pointer is a symlink, so this reads one aliases file under each of its names.
  # That is intended: localpart@pointer is a recipient Exim accepts on its own and
  # allowlists separately. See "Domain pointers" below before acting on one.
  awk -F: '/ses-gmail-forward/ && $0 !~ /^[[:space:]]*#/ {
    n = split(FILENAME, p, "/"); a = $1
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", a)
    print tolower(a "@" p[n-1])
  }' /etc/virtual/*/aliases | sort -u
}
has_mailbox() {  # has_mailbox user1@example.com
  grep -qE "^${1%@*}:" "/etc/virtual/${1#*@}/passwd" 2>/dev/null
}
allowlist() {
  aws secretsmanager get-secret-value \
    --secret-id tellerstech/ses-gmail-forward/runtime-config \
    --query SecretString --output text \
    | python3 -c 'import json,sys
for a in json.load(sys.stdin)["recipients"]: print(a.strip().lower())' | sort -u
}

# piped but not allowlisted, split by whether the message survives
while read -r a; do
  has_mailbox "$a" && echo "no Gmail copy: $a" || echo "DISCARDED: $a"
done < <(comm -23 <(pipe_addrs) <(allowlist))

comm -13 <(pipe_addrs) <(allowlist)   # allowlisted, not piped: no Gmail copy, still in Roundcube
```

Any `DISCARDED:` line is losing mail and needs fixing now. `no Gmail copy:` lines are
worth understanding but lose nothing — and some are expected, so read the next section
before deleting an alias, because one shape of entry must **not** be fixed that way. The
final list also loses nothing but means Gmail never sees that address.

The health check runs the same comparison against `managed-aliases.conf` every 5 minutes,
failing on `pipe_alias_no_mailbox:<address>` and logging the harmless case as `NOTE piped
but not forwarded, mailbox still receives`. It deliberately reads the local desired-state
file rather than the secret, to keep an AWS credential out of the cron path — which is why
the comparison above against the real allowlist is still worth running by hand after
editing either one.

### Domain pointers share one aliases file — never edit the pointer's path

A DirectAdmin **domain pointer** is a symlink, not a copy:

```console
$ ls -ld /etc/virtual/origin.aws.tellerstech.com
lrwxrwxrwx 1 mail mail 15 … /etc/virtual/origin.aws.tellerstech.com -> tellerstech.com

$ ls -li /etc/virtual/{tellerstech.com,origin.aws.tellerstech.com}/aliases
64706539 -rw------- … /etc/virtual/origin.aws.tellerstech.com/aliases
64706539 -rw------- … /etc/virtual/tellerstech.com/aliases      # same inode
```

Two consequences, both of which have already bitten:

**Editing the pointer's path edits the target's file.** `sed -i` on
`/etc/virtual/origin.aws.tellerstech.com/aliases` resolves the directory symlink and
rewrites `tellerstech.com`'s aliases — so "removing the parked domain's forwarders"
silently removed forwarding for the live domain instead. This happened on
2026-09-12: `brian@` and `bteller@tellerstech.com` lost their pipe until the enforcer
restored it (`FIXED tellerstech.com: restored pipe aliases`) about 80 seconds later,
which is precisely the drift the enforcer and its cron exist to catch. No mail was
delivered to either address in the gap, so nothing was lost — by luck, not design.

**`/etc/virtual/*/aliases` reads that one file under each name, and that is correct.**
`localpart@pointer` is a recipient Exim accepts in its own right — the pointer is in
`/etc/virtual/domains`, the shared aliases give it the pipe, and `recipients` allowlists it
separately — so it is a real address, not a duplicate. It just is not a *fixable* one:

```console
$ exim -bt brian@origin.aws.tellerstech.com
brian@origin.aws.tellerstech.com -> |/usr/local/bin/ses-gmail-forward.py
  transport = virtual_address_pipe
brian@origin.aws.tellerstech.com
    <-- brian@origin.aws.tellerstech.com
  router = virtual_mailbox, transport = dovecot_lmtp_udp
```

The pointer's local-parts share the target's `passwd`, so they have mailboxes and `unseen`
gives each one a Maildir copy. That copy is **not** in a separate pointer mailbox: the mail
store is symlinked exactly like the config directory, so it lands in the target's Maildir —
the one already open in Roundcube.

```console
$ ls -ld /home/tellerstec/imap/origin.aws.tellerstech.com
lrwxrwxrwx 1 tellerstec mail 15 … origin.aws.tellerstech.com -> tellerstech.com

$ ls -ldi /home/tellerstec/imap/{tellerstech.com,origin.aws.tellerstech.com}/brian/Maildir/cur
358646309 drwx------ … origin.aws.tellerstech.com/brian/Maildir/cur
358646309 drwx------ … tellerstech.com/brian/Maildir/cur         # same inode
```

Mail to a pointer address is therefore **not** lost, and there is no second inbox to go
read — which is why check 6 logs it as a `NOTE` instead of failing. The only thing missing
is the Gmail copy.

Do not read that shared store as proof the pointer is *receiving* anything. Every message
in it currently carries `Delivered-To: brian@tellerstech.com`, so no pointer-addressed mail
has actually arrived; the `NOTE` describes an address the config would accept, not observed
traffic. Confirm with `grep -m1 -i '^Delivered-To:'` over the newest few files before
treating a `NOTE` as evidence of anything.

The remedies, if you want even the Gmail copy, are to add the pointer address to
`recipients` or to remove the pointer's mail handling in DirectAdmin. Editing the aliases
file is never one of them. For a pointer that exists only as a CDN origin hostname,
leaving it alone is the right answer.

List the pointers on a host before believing any per-domain finding. Both trees are
symlinked, so check both — the config tree tells you which addresses exist, the mail tree
tells you where their mail actually lands:

```bash
find /etc/virtual -maxdepth 1 -type l -printf '%p -> %l\n'
find /home/*/imap -maxdepth 1 -type l -printf '%p -> %l\n'
```

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

# Health check (self-heal aliases + alert on recent ERROR / silent SES skips /
# pipe aliases with no matching config entry)
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

A recipient that is not in the allowlist at all is **not** in this table: it is declined
earlier, at `INFO`, with no structured reason. That is deliberate for a mailbox Exim also
delivers normally, but it means the log says nothing useful when the alias made the pipe
the *only* delivery path — see
[Only put the pipe on addresses that are in `recipients`](#only-put-the-pipe-on-addresses-that-are-in-recipients),
which the health check now covers as `pipe_alias_no_mailbox:<address>`.

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

### …and never writes to stderr, not even a warning

The stdout/stderr half of that is not folklore. The transport sets it explicitly:

```text
virtual_address_pipe:
  driver = pipe
  group = nobody
  return_output
  user = "${lookup{$domain_data}lsearch* {/etc/virtual/domainowners}{$value}}"
```

`return_output` means output *is* failure: produce a byte on either stream and Exim
returns the message to the sender as a bounce **even when the exit status is 0**, after
the mailbox copy and the SES copy have both already gone out. A library's
`DeprecationWarning` is enough to trigger it, which is why the script silences warnings
before importing boto3 rather than trusting the environment.

That `user =` line is also why the pipe has no single uid: it runs as the **domain
owner** from `/etc/virtual/domainowners`, so `tellerstech.com` runs as one account and
`wbat.net` as another. They need not resolve the same dependencies — a stale
`~/.local/lib/python3.9/site-packages/boto3` under one owner shadows the system copy for
that domain only, which is how one domain can start emitting warnings that the other
never does. Check with:

```bash
for u in $(awk -F': *' '{print $2}' /etc/virtual/domainowners | sort -u); do
  printf '%-12s ' "$u"
  su -s /bin/bash "$u" -c 'python3 -c "import boto3;print(boto3.__version__, boto3.__file__)"'
done
```

## Gmail (outbound)

| Setting | Value |
|---|---|
| SMTP server | `email-smtp.us-east-1.amazonaws.com` |
| Port | `587` + TLS |
| Auth | SES SMTP username/password |
| Treat as alias | **No** — see below |
| Entries needed | one per allowlisted **address**, not per domain — `user1@example.com` and `user2@example.com` need two entries |
| Default Send mail as | Domain address (e.g. `user1@example.com`) |
| When replying | Reply from the same address the message was sent to — see below |

Profile photo for `@example.com` From in Gmail recipients is limited without Google Workspace.

### Treat as alias must be off, or Reply-All disappears

This is the one Gmail setting that undoes the header work. With **Treat as an alias**
checked, Gmail counts that address as *you*, and the forwarded copy comes **From** it —
so Gmail reads the message as one you sent. For your own messages it collapses Reply and
Reply-All into a single Reply aimed at the recipients, and the Reply-All button is simply
not offered. Every recipient is still in the headers; there is just no longer a control
that uses them.

The symptom is per-domain and easy to misread, because it depends on how each address
happens to be configured rather than on anything in the message:

| `Send mail as` entry for the alias | What Gmail shows on the forwarded copy |
|---|---|
| Treat as an alias: **Yes** | Reply only, which goes to everyone |
| Treat as an alias: **No** | Reply to the sender, Reply-All to everyone |
| Not listed at all | Reply to the sender, Reply-All to everyone — but your replies go out from your Gmail address, not the domain |

Unchecking it does not affect sending: the address stays in **Send mail as** and still
authenticates through SES. Every allowlisted address funnelling into one inbox should be
configured the same way, or the same message will behave differently depending on which
alias it arrived at. Gmail keys all of this off the full address, not the domain, so an
address left out is a third state rather than an inherited setting — check every one of
them under Settings → Accounts and Import → Send mail as → *edit info*.

### Which address a reply goes out as

Gmail picks the reply identity from the address the message was sent to, and on a
forwarded copy that is your Gmail address — the alias was swapped out on purpose, because
leaving it in `To` is what would send a Reply-All back through this pipe as a second copy
of itself. So Gmail will not pick the domain address on its own, however the aliases are
configured.

That leaves a choice with no clean answer, and it is worth making deliberately:

| `When replying` | Result |
|---|---|
| Reply from the same address the message was sent to | Consistent across domains, but replies leave as your Gmail address unless you change the From dropdown |
| Always reply from default address | Deterministic, but brands *every* reply with one domain, including replies to mail that arrived at the other |

With more than one domain in play the first is the safer default, with the From dropdown
switched by hand where the domain matters. The second is only right if one domain is the
only one you ever reply as.

Either way the dropdown only offers addresses that have a **Send mail as** entry, which is
the practical reason to add all of them rather than only the busy ones: an allowlisted
address with no entry can never be replied as, even deliberately.

Adding an address here sends a confirmation code to it. That code reaches the **mailbox**
regardless, because Exim delivers it independently of this pipe — but it may never reach
Gmail, since auto-generated mail is deliberately skipped (see
[Skip guards](#skip-guards-pipe--ses)). Read it in Roundcube rather than resending.

## DMARC, SPF, DKIM

The pipe resends someone else's mail *as one of your own addresses*, so whether the
forwarded copy authenticates for your domain decides whether Gmail files it as spam.

It passes, on DKIM. SES has Easy DKIM verified and signing enabled for both domains, and
the forwarded `From` and the SES `Source` are the same allowlisted address, so the `d=`
SES signs with is the `From` domain. DMARC needs only one aligned pass, and that is it.

SPF never aligns, and that is fine:

```console
$ aws sesv2 get-email-identity --email-identity tellerstech.com \
    --query 'DkimAttributes.{Status:Status,Signing:SigningEnabled}'
{
    "Status": "SUCCESS",
    "Signing": true
}

$ aws sesv2 get-email-identity --email-identity tellerstech.com \
    --query 'MailFromAttributes.MailFromDomain'
null
```

A `null` MAIL FROM domain means SES uses its own envelope sender under `amazonses.com`, so
the SPF check runs against `amazonses.com` and not against you. **That is why adding
`include:amazonses.com` to your SPF record does nothing for DMARC** — SPF alignment is
evaluated against the envelope MAIL FROM domain, never the header `From`, so the include
authorises a domain that is not the one being compared. Leave SPF alone. The real change,
if you ever want a second aligned pass before moving off `p=none`, is a custom MAIL FROM
domain in SES: an MX plus a TXT record per domain.

### Why the copy has to authenticate as us

Forwarding always breaks SPF alignment, because the relaying host is not in the original
sender's SPF record. On its own that is survivable: DMARC needs only one aligned pass, and
an unmodified DKIM signature travels with the message — which is why plain forwarding
usually still passes, and why a forwarder is not obliged to rewrite anything.

This pipe cannot lean on that, and not by accident. It removes the original signature, and
rewrites the one header RFC 6376 §5.4 requires every signer to cover:

```python
    for header in (
        "DKIM-Signature",
        "DomainKey-Signature",
        "Return-Path",
        "Sender",
        "Reply-To",
        "To",
        "Cc",
        "From",
        "Message-ID",
    ):
        if header in msg:
            del msg[header]
```

So by the time SES is handed the message the original authentication is gone by
construction — SPF unaligned by the relay, DKIM deleted, and unverifiable regardless once
`From` changed. Re-signing as our own domain is not hardening, it is the only
authentication the copy has left.

The upside is that DMARC is then evaluated against *our* domain rather than the sender's,
so however strict a policy they publish, it does not apply to this path. Worth stating
carefully, though: `p=reject` is a requested disposition that receivers may override, not a
guaranteed bounce, so this removes a failure mode rather than one that was certain.

### `rua=` on a domain you do not control collects nothing

A DMARC record whose `rua` mailbox sits on a different domain from the record itself is an
*external destination*, and RFC 7489 §7.1 requires that domain to opt in by publishing an
authorisation record. Reporters that follow the spec — Google, Microsoft, Yahoo — send
nothing to an unauthorised destination. So `rua=mailto:…@gmail.com` collects nothing:

```console
$ dig +short TXT wbat.net._report._dmarc.gmail.com
$ dig +short TXT tellerstech.com._report._dmarc.gmail.com
        # both empty — gmail.com authorises no one to report to it
```

Publishing that record, wildcarded, is part of what a report processor is for:

```console
$ dig +short TXT wbat.net._report._dmarc.dmarc.postmarkapp.com
"v=DMARC1;"
```

So pointing `rua` at your own Gmail is not a lightweight version of DMARC reporting, it is
reporting that silently never happens. Point `rua` at a processor, and check the
authorisation resolves for *your* domain name before believing reports will arrive:

```bash
dig +short TXT wbat.net._report._dmarc.<processor-report-domain>   # expect "v=DMARC1"
```

`rua` takes a comma-separated list, but authorisation is checked **per destination** — a
second address does not inherit the processor's. So adding the Gmail address alongside it
buys no confirmation channel; it fails for exactly the reason above. If you want a raw copy
while setting up, use a mailbox on the policy domain itself, which is not an external
destination and needs no authorisation record:

```
_dmarc.wbat.net  TXT  "v=DMARC1; p=none; rua=mailto:<token>@<processor>,mailto:dmarc@wbat.net"
```

Drop the second entry once reports are arriving — the raw files are zipped XML that no one
reads by hand.

## What not to do

- Do not set MX to `inbound-smtp.*.amazonaws.com` for this domain.
- Do not add `include:amazonses.com` to SPF expecting it to help DMARC (see above).
- Do not point `rua=` at a mailbox on a domain that does not authorise you (see above).
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
