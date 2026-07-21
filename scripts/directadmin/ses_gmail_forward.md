# DirectAdmin → Roundcube + Gmail via SES pipe

**Keep MX on DirectAdmin.** Use Forwarders with a **pipe-only** destination.
The script delivers to Maildir via `dovecot-lda`, then sends a SES copy to Gmail.

Do **not** use bare `brian` or `\brian@domain` in aliases — on this DA/Exim setup
those become `brian@server.wbat.net` or `\\brian@...` and LMTP rejects them.

## DirectAdmin

1. Keep the **Email Account** (needed for the mailbox/Maildir).
2. **Forwarders** → destination exactly:

```text
|/usr/local/bin/ses-gmail-forward.py
```

3. Confirm aliases are pipe-only:

```bash
grep -E '^(brian|bteller):' /etc/virtual/tellerstech.com/aliases
```

```text
brian: "|/usr/local/bin/ses-gmail-forward.py"
bteller: "|/usr/local/bin/ses-gmail-forward.py"
```

## One-time server setup

```bash
curl -fsSL -o /usr/local/bin/ses-gmail-forward.py \
  https://raw.githubusercontent.com/wbat/wbat-terraform/main/scripts/directadmin/ses_gmail_forward.py
chmod 755 /usr/local/bin/ses-gmail-forward.py

mkdir -p /var/lib/ses-gmail-forward
touch /var/log/ses-gmail-forward.log
chmod 666 /var/log/ses-gmail-forward.log
chmod 777 /var/lib/ses-gmail-forward

# Confirm lda exists
ls -la /usr/libexec/dovecot/dovecot-lda /usr/sbin/dovecot-lda 2>/dev/null
python3 -c 'import boto3; print(boto3.__version__)'
```

Populate Secrets Manager `tellerstech/ses-gmail-forward/runtime-config` with
`gmail_destination` + `recipients` allowlist.

## Flow

```
Internet → MX DA → alias pipe → ses-gmail-forward.py
                                  ├─ dovecot-lda → Roundcube Maildir
                                  └─ SES SendRawEmail → Gmail
```

## Test

External mail → allowlisted address → Roundcube + Gmail + log line, no bounce.
