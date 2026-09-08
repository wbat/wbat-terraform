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
2. **A rate limiter that actually bans** — CSF's lfd here, fail2ban elsewhere;
   covers every remaining password path, chiefly DirectAdmin, mail, and FTP,
   which cannot go key-only.
3. **A restricted 2222** — takes the DirectAdmin panel off the open internet.

A fourth is not about the names at all but shows up in the same audit: no
datastore should be listening on a public interface. `lfd` and `fail2ban` do not
sit in front of MySQL, and a success there is the whole dataset rather than one
account. See [Bound is not the same as reachable](#bound-is-not-the-same-as-reachable).

## Measure first

```bash
sudo /usr/local/sbin/host-access-audit.sh          # or run from the repo
sudo /usr/local/sbin/host-access-audit.sh --json   # for automation
```

Read-only: it never edits a config, restarts a service, or touches a firewall.
Do not skip it — the steps below are written against what it reports, and
several of them are no-ops or actively wrong depending on the baseline. Two
readings in particular are not what they first look like:

- `exposure/da-panel` is a statement of fact, not a verdict: 2222 bound and
  passed by `TCP_IN` only means the host accepts the connection. Whether
  anything can reach it is `exposure/da-panel-sg`, which asks EC2 — and usually
  skips, because the instance profile cannot describe security groups. Run the
  command it prints from a workstation.
- `ratelimit/lfd-coverage` failing names services whose lfd threshold is `0`.
  That is a service nobody is watching, not a missing tool, and installing
  fail2ban would make it worse rather than better.
- `fail2ban/effective` reporting zero bans for a jail on an internet-facing
  host almost always means it is watching a logpath that does not exist on this
  distro — a different problem from fail2ban being absent, with a different fix.

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

## 2. A rate limiter that demonstrably bans

DirectAdmin, mail, and FTP all accept passwords by design and cannot be made
key-only, so this is what protects them.

**Check which engine this host already runs before installing anything.** Two
tools do this job and the box should have exactly one:

```bash
sudo systemctl is-active lfd        # CSF's login failure daemon
sudo systemctl is-active fail2ban
```

CSF/lfd is what a DirectAdmin build normally ships, and it is what
`server.wbat.net` runs. **Do not add fail2ban next to it.** Both write their own
iptables rules from their own state, so they unblock each other's bans and you
end up with less protection than either alone, plus a firewall nobody can
reason about. If `lfd` is active, skip the install and go to the CSF section
below.

<details>
<summary>If neither is present, and you are choosing fail2ban</summary>

```bash
sudo dnf install -y fail2ban
sudo systemctl enable --now fail2ban
```

</details>

### CSF/lfd

lfd's per-service thresholds live in `/etc/csf/csf.conf`. A setting of `0`
disables watching for that service entirely, so read the values, not the keys:

```bash
sudo grep -E '^LF_(SSHD|DIRECTADMIN|SMTPAUTH|POP3D|IMAPD|FTPD)' /etc/csf/csf.conf
```

Every one of those should be a small non-zero number — they map exactly onto the
password paths the published account names can reach. `LF_DIRECTADMIN=0` in
particular means the 2222 panel is unmetered, which is the highest-value target
on the box.

After any change: `sudo csf -r` to reload.

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
sudo fail2ban-client get directadmin logpath   # does that path exist?
sudo journalctl -u fail2ban | grep -i "already exists\|no such file"
```

Check every jail, not the total. On an internet-facing host the sshd jail
accumulates bans within hours, and that is enough to make a summed figure look
healthy while the DirectAdmin or mail jail — watching a path this distro does
not use — has banned nobody since it was installed. Those are the endpoints the
disclosed account names actually expose.

If a jail's `Total banned` is still 0 after a day, check its `logpath` against
where this distro really writes auth failures (`/var/log/secure` on EL, not
`/var/log/auth.log`). The audit reports this per jail: `fail2ban/logpath` fails
outright when a watched path is absent, and `fail2ban/effective` names each
permanently quiet jail rather than summing them.

## 3. Restrict 2222

The DirectAdmin panel on 2222 is the highest-value target for the disclosed
names: it is a password login, it is enumerable, and a success is account
takeover rather than a shell on one site.

Restrict at the **security group**, not the host firewall — it is out of band
from the box, it cannot be undone by a DA update, and getting it wrong cannot
strand you because SSM is unaffected either way.

That security group is managed in this repository, so the change belongs in a
PR and an HCP Terraform apply rather than in the console. Both instances take
their group from `data.aws_security_group.default`, which resolves to
`aws_security_group.default` in `aws/us-east-1/sg/default.tf` (wired in as
`module "sg"`).

**Read this before editing that file.** The resource declares the group but no
rules, so `ingress` and `egress` are computed: Terraform currently adopts
whatever rules exist and leaves them alone. Adding an inline `ingress` block
changes that — the provider would then treat the declared set as the complete
set and revoke every rule you did not write down, including 80, 443 and 22.
That is an immediate outage for all sites on the box.

So the restriction is expressed as its own resources, which do not take over
the rest of the group. That is already written, in
[aws/us-east-1/sg/da-panel.tf](../us-east-1/sg/da-panel.tf), covering three
kinds of source:

| Source | How it is expressed | Why |
|--------|--------------------|-----|
| Your own addresses | `var.da_panel_allowed_cidrs`, a `label => CIDR` map | The only human path once 2222 is closed |
| `server.wbat.net`, `server2.wbat.net` | The managed EIPs, `/32` each | A panel connection made *by hostname* between the two boxes resolves to the public address, leaves through the internet gateway, and arrives from the EIP — not the private address |
| Either instance over the private path | A security-group self-reference | Survives a private-IP change, which this estate has already had once |

### Setting your addresses

`da_panel_allowed_cidrs` is declared in
[aws/credentials.tf](../credentials.tf) with an empty default, and the real
value belongs in a **Terraform Cloud workspace variable**, not in a commit.
This repository is public and a residential address is personal data:

```hcl
# HCP Terraform → workspace wbat-terraform-aws → Variables
da_panel_allowed_cidrs = { home = "203.0.113.10/32" }
```

The empty default is load-bearing. With no entries, no operator rule is
created and nothing changes, so a missing variable cannot lock anyone out by
omission.

### State as of the last apply

2222 is **closed to the internet**. The world-open rule was revoked and
`da-panel.tf` applied, and `da_panel_allowed_cidrs` is currently empty, so the
only rules on 2222 are the two server EIPs and the group self-reference. Panel
access is therefore by SSM port-forward only, which is the end state described
below rather than a gap to fix.

Verified from outside AWS, from a host on no allowlist: 2222 and 3306 both
time out while 443 answers. The timeout rather than a refusal is the tell — a
security group drops, where a host firewall rejecting or a closed port returns
`RST` immediately. Port 22 also times out from there, which is worth knowing
because CSF's `TCP_IN` does allow 22: SSH is restricted at the security group,
not by the host, so a broken allowlist entry cannot be worked around by
falling back to SSH from an arbitrary address. SSM remains the path that does
not depend on any of this.

The procedure below is kept for the next time these rules change.

### The order that avoids locking yourself out

Adding these rules **does not close 2222**. The existing `0.0.0.0/0` rule was
created outside Terraform and is not in state, so no apply will remove it. That
is convenient here: it means the new rules can be applied and *verified* while
the old one is still holding the door open.

1. **Set the variable and apply.** 2222 is now reachable both from the world
   and from your allowlist. Effective access is unchanged, so this step cannot
   break anything.

2. **Check Terraform's view matches your intent**, using the output added for
   this purpose:

```bash
terraform output da_panel_allowed_sources
```

3. **Prove the new rule is the one letting you in.** While both rules exist you
   cannot tell them apart from a browser, so confirm the rule exists in AWS with
   your address on it:

```bash
aws ec2 describe-security-groups --profile wbat --region us-east-1 \
  --group-ids sg-0e674f4e2937c6392 \
  --query "SecurityGroups[].IpPermissions[?IpProtocol=='-1' || (FromPort<=\`2222\` && ToPort>=\`2222\`)][].[IpRanges[].[CidrIp,Description], Ipv6Ranges[].[CidrIpv6,Description], UserIdGroupPairs[].[GroupId,Description]][][]" \
  --output text
```

Three details in that filter are load-bearing, and each one is a way for an
open 2222 to look closed: the `[]` after the filter (without it the projection
stays nested per security group and a trailing `.IpRanges[].CidrIp` evaluates to
nothing at all), the IPv6 and group-reference columns, and matching a *range*
containing 2222 plus `-1` all-traffic rules, which carry no `FromPort`.
`exposure/da-panel-sg` in the audit asks the same question with the same filter.

4. **Then revoke the world-open rule**, and keep the command that puts it back
   in your shell history before you run it:

```bash
# Undo, if you lock yourself out and want the old behaviour back immediately:
#   aws ec2 authorize-security-group-ingress --profile wbat --region us-east-1 \
#     --group-id sg-0e674f4e2937c6392 --protocol tcp --port 2222 --cidr 0.0.0.0/0
aws ec2 revoke-security-group-ingress --profile wbat --region us-east-1 \
  --group-id sg-0e674f4e2937c6392 --protocol tcp --port 2222 --cidr 0.0.0.0/0
```

5. **Load the panel from your allowed address, and from a phone on cellular.**
   The first must work, the second must not.

Do not import the world-open rule into Terraform just to delete it. Import then
destroy is two applies where a revoke is one command, and the rule is
`0.0.0.0/0` — there is nothing worth preserving in state.

### When your address changes

A residential address is dynamic, so plan for this rather than being surprised
by it. In order of preference:

- **SSM port-forward**, which needs no ingress at all and is unaffected by any
  of the above:

```bash
aws ssm start-session --profile wbat --region us-east-1 --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["2222"],"localPortNumber":["2222"]}'
# then browse https://localhost:2222
```

- **Update the workspace variable and apply.** No PR needed, since the value
  lives in HCP Terraform rather than in the repository.
- **Add the address temporarily by hand**, then reconcile into the variable.
  Anything added this way is invisible to Terraform and will outlive its
  usefulness, so treat it as a stopgap.

### Before you revoke: what else talks to 2222?

Nothing on the box needs it — DirectAdmin's own outbound calls for licensing
and updates are not ingress. What does break is anything *external* that drives
the DirectAdmin **API** on 2222, because the API and the panel share the port:

- billing or provisioning systems (WHMCS and similar) that create accounts
- off-box backup or migration tooling
- uptime monitors probing 2222, which will start alerting

This estate hosts a `billing.` hostname, so confirm where it runs before you
revoke. If it is on this box it uses localhost and is unaffected; if it is
elsewhere, add its address to the allowlist in step 1 or it will fail silently
at the next provisioning event.

That is the better end state: 2222 closed to the internet entirely, reachable
only to an authenticated AWS principal.

## Bound is not the same as reachable

The audit lists every port bound to `0.0.0.0`, then judges them against CSF's
`TCP_IN`. Those are two different facts and they call for different responses:

```bash
sudo ss -lntp | grep '0\.0\.0\.0'          # what is listening on every interface
sudo grep -E '^(TCP_IN|TCP6_IN)' /etc/csf/csf.conf   # what CSF lets in
```

A port that is bound **and** in `TCP_IN` is reachable from the internet right
now. A port that is bound but absent from `TCP_IN` is firewalled today and
exposed the moment CSF is stopped, flushed, or reinstalled — which happens
during maintenance, and it is not a state you want a database in.

`3306` is the one to care about on this host. Neither lfd nor fail2ban rate
limits MySQL, and a compromise there is every site's data rather than one
account. If nothing connects to MySQL over the network — and on a single-box
DirectAdmin build nothing does, since PHP talks to it over localhost — bind it
to loopback:

```ini
# /etc/my.cnf, under [mysqld]
bind-address = 127.0.0.1
```

Then `systemctl restart mysqld` (or `mariadb`) and re-run the audit;
`exposure/datastore` should go to `OK`. Restarting the database drops open
connections, so treat it as a brief maintenance window rather than a live edit.

The plaintext mail and FTP ports (`21`, `110`, `143`) are a lower-grade version
of the same question: they accept credentials without implicit TLS, and their
TLS-native equivalents (`465`, `993`, `995`) are already open. Closing them is a
client-compatibility decision, not a technical one, so the audit warns rather
than failing.

## Verify

```bash
sudo /usr/local/sbin/host-access-audit.sh
```

Run it with `sudo`. Unprivileged it cannot read `sshd -T`, the fail2ban socket
or `directadmin.conf`, and it will say so: skipped checks are counted, the run
is reported `INCOMPLETE`, and it exits 3. Exit 0 means the audit was both
complete and clean — nothing else does.

Target state is no `FAIL`, no `SKIP`, and `WARN` only where you have made a
deliberate choice. Two skips are expected to need attention rather than
privilege:

- `ssm/reachable` — the audit asks Systems Manager for `PingStatus`, which the
  instance profile normally cannot do. Run the command it prints from your
  workstation before you touch `sshd`. A running agent is not a recovery path;
  an `Online` ping is. This is the check that decides whether step 1 is safe.
- `ssh/match` — resolvable only with root, and only for `Match User`/`Match
  Group` contexts. Address-keyed blocks cannot be enumerated by probing, so if
  the audit warns `ssh/match-coverage`, read those blocks by hand.

Re-run after any DirectAdmin update — `update_post` hooks are the usual way an
`sshd_config` or jail change gets quietly reverted.

## What this does not fix

Hardening does not un-publish the names, and it does not help if a password is
already weak or reused. Rotating DirectAdmin passwords for the disclosed
accounts is a reasonable follow-up, and unlike the hardening above it needs
coordination with the account holders.
