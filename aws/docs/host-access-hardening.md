# Host access hardening: making the disclosed account names useless

## Why this is the control that matters

This repository is public, and its git history contains a verbatim `nginx -T`
capture of the primary. The DirectAdmin account names in that capture are
permanently disclosed — [#123](https://github.com/wbat/wbat-terraform/pull/123)
placeholdered the working tree, which stops search engines and code search from
surfacing them, but `git log -p` still reaches the original and rewriting
history would break every clone and fork.

So treat the names as public and move the control somewhere it still works.
A username is only half a credential, and the half that matters is guarded by
authentication, not by secrecy. Several of these names appear in email addresses
anyway, so they were never really private.

Three changes make the disclosure inert:

1. **Key-only SSH** — no password path to guess against.
2. **A fail2ban that actually bans** — rate-limits every remaining password
   path, chiefly DirectAdmin, mail, and FTP, which cannot go key-only.
3. **A restricted 2222** — takes the DirectAdmin panel off the open internet.

## Measure first

```bash
sudo /usr/local/sbin/host-access-audit.sh          # or run from the repo
sudo /usr/local/sbin/host-access-audit.sh --json   # for automation
```

Read-only: it never edits a config, restarts a service, or touches a firewall.
Do not skip it — the steps below are written against what it reports, and
several of them are no-ops or actively wrong depending on the baseline. In
particular, `fail2ban/effective` reporting zero bans on an internet-facing host
almost always means a jail is watching a logpath that does not exist on this
distro, which is a different problem from fail2ban being absent and has a
different fix.

## The safety net: SSM is not on the path you are about to break

Every change below can, if botched, cut SSH. That is survivable here because
Session Manager does not depend on `sshd`, port 22, port 2222, or any
security-group ingress — it is an outbound agent connection authorised by the
instance profile, which already carries `AmazonSSMManagedInstanceCore` in
[role-WBAT_Main_Server.tf](../global/iam/role-WBAT_Main_Server.tf).

That makes SSH lockdown materially safer here than on a typical box, but only
while the agent is healthy. So:

```bash
# BEFORE each step. If this is not Online, stop -- you have no way back in.
aws ssm describe-instance-information --profile wbat --region us-east-1 \
  --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output table
```

The audit's `ssm/agent` check is the on-box equivalent. Keep a second SSH
session open as well: it costs nothing and it is faster than opening a session
when you are already locked out.

## 1. Key-only SSH

Confirm you can authenticate with a key **before** removing the password path,
and confirm the account you rely on actually has a key installed:

```bash
sudo awk -F: '$3>=500 && $7 !~ /(nologin|false)$/ {print $1, $6}' /etc/passwd \
  | while read -r u h; do printf '%-16s %s\n' "$u" \
      "$( [ -s "$h/.ssh/authorized_keys" ] && echo has-key || echo NO-KEY )"; done
```

Then set all three options. Setting only the first is the most common mistake
and it leaves the box brute-forceable through PAM:

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
```

Prefer a drop-in over editing the main file, so a DirectAdmin or OS update that
rewrites `sshd_config` does not silently revert this:

```bash
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' \
  | sudo tee /etc/ssh/sshd_config.d/10-hardening.conf
sudo sshd -t                       # GATE: syntax must pass before reload
sudo systemctl reload sshd         # reload, not restart -- keeps live sessions
sudo sshd -T | grep -E 'passwordauthentication|kbdinteractive|permitrootlogin'
```

Drop-ins require `Include /etc/ssh/sshd_config.d/*.conf` in the main config,
which is default on AlmaLinux/Rocky 9 but not on older builds — the audit reads
effective config via `sshd -T`, so re-run it to confirm the setting actually
took rather than assuming the file was read.

Rollback: delete the drop-in, `sshd -t`, reload.

## 2. fail2ban that demonstrably bans

DirectAdmin, mail, and FTP all accept passwords by design and cannot be made
key-only, so this is what protects them.

```bash
sudo dnf install -y fail2ban
sudo systemctl enable --now fail2ban
```

DirectAdmin ships log scanning that writes to `/var/log/directadmin/security.log`
and can feed a jail. Enable DA's own scanner too — it catches panel, FTP, and
mail attempts that a generic sshd jail never sees:

```bash
grep -E '^brute_force_log_scanner|^brute_force' /usr/local/directadmin/conf/directadmin.conf
```

Set `brute_force_log_scanner=1` if absent, then `systemctl restart directadmin`.

The step people skip is verification. A jail whose `logpath` does not exist
stays `active` forever and bans nothing:

```bash
sudo fail2ban-client status                    # jails present?
sudo fail2ban-client status sshd               # "Total banned" climbing?
sudo journalctl -u fail2ban | grep -i "already exists\|no such file"
```

On an internet-facing host, sshd bans appear within hours. If `Total banned`
is still 0 after a day, the jail is misconfigured — check `logpath` against
where this distro actually writes auth failures (`/var/log/secure` on EL, not
`/var/log/auth.log`). The audit's `fail2ban/effective` check exists precisely
to surface this.

## 3. Restrict 2222

The DirectAdmin panel on 2222 is the highest-value target for the disclosed
names: it is a password login, it is enumerable, and a success is account
takeover rather than a shell on one site.

Restrict at the **security group**, not the host firewall — it is out of band
from the box, it cannot be undone by a DA update, and getting it wrong cannot
strand you because SSM is unaffected either way. Note the security groups are
not currently managed in this repo, so this is a console or CLI change:

```bash
# Inspect what is currently allowed to 2222
aws ec2 describe-security-groups --profile wbat --region us-east-1 \
  --query "SecurityGroups[].IpPermissions[?FromPort==\`2222\`].[IpRanges[].CidrIp]" --output text
```

Replace `0.0.0.0/0` with your fixed addresses. If your address is dynamic,
prefer reaching the panel through an SSM port-forward, which needs no ingress
at all:

```bash
aws ssm start-session --profile wbat --region us-east-1 --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["2222"],"localPortNumber":["2222"]}'
# then browse https://localhost:2222
```

That is the better end state: 2222 closed to the internet entirely, reachable
only to an authenticated AWS principal.

## Verify

```bash
sudo /usr/local/sbin/host-access-audit.sh
```

Target state is no `FAIL`, and `WARN` only where you have made a deliberate
choice. Re-run after any DirectAdmin update — `update_post` hooks are the usual
way an `sshd_config` or jail change gets quietly reverted.

## What this does not fix

Hardening does not un-publish the names, and it does not help if a password is
already weak or reused. Rotating DirectAdmin passwords for the disclosed
accounts is a reasonable follow-up, and unlike the hardening above it needs
coordination with the account holders.
