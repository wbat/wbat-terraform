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

Steps 1–3 are done. Two findings remain, and neither is about guessing a name:

4. **[An SSH allowlist](#4-limit-ssh-to-the-accounts-that-need-it)** — with
   passwords already off, the risk is not guessing. Site PHP can write its own
   owner's `~/.ssh/authorized_keys`, so any of the 14 shell accounts is a route
   from a compromised website to durable interactive SSH. This is the largest
   item left.
5. **A datastore on a public interface** — not about the names at all, but it
   shows up in the same audit. Neither `lfd` nor `fail2ban` sits in front of
   MySQL, and a success there is the whole dataset rather than one account. See
   [Bound is not the same as reachable](#bound-is-not-the-same-as-reachable).

The plaintext mail and FTP ports are the remaining password surface now that
SSH and 2222 are closed — see
[The plaintext mail and FTP ports are now the last password path](#the-plaintext-mail-and-ftp-ports-are-now-the-last-password-path).

## Measure first

```bash
# The audit is installed with the rest of the host tooling, so pull and install
# first -- an audit predating the checks it is trusted to make is the one kind
# of stale copy that actively misleads.
cd /root/wbat-terraform && git pull
sudo ./scripts/directadmin/install_da_vhost_listen.sh --install

sudo /usr/local/sbin/host-access-audit.sh          # read-only posture report
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

`sudo` has to be on the file test, not only on the `awk`. A pipeline runs the
loop in the *calling* shell, and a `.ssh` directory is mode 700, so an
unprivileged reader gets `NO-KEY` for every account whether or not a key is
there — including in the `ssm-user` session this runbook sends you to:

```bash
sudo awk -F: '$3>=500 && $7 !~ /(nologin|false)$/ {print $1, $6}' /etc/passwd \
  | while read -r u h; do
      if sudo test -s "$h/.ssh/authorized_keys"; then k=has-key; else k=NO-KEY; fi
      printf '%-16s %s\n' "$u" "$k"
    done
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

## 4. Limit SSH to the accounts that need it

With passwords off and 2222 closed, this is the largest remaining item, and the
audit's one-line `ssh/allowlist` warning undersells it. The problem is not brute
force — key-only SSH is not brute-forceable. It is that **a DirectAdmin home
directory is writable by that site's own PHP.** A compromised site can append a
key to its owner's `~/.ssh/authorized_keys`, and `sshd` will honour it: the file
is owned by the right user with sane permissions, which is all `StrictModes`
asks. A web compromise then becomes an interactive shell that survives cleaning
up the website, and nothing in the audit's other checks would notice.

This host has 14 accounts with a login shell and no allowlist, so every one of
them is that path today. An allowlist closes it by refusing the account at
authentication time whether or not a key was planted.

See which accounts could be used this way. Note the `sudo` on the file test and
the absence of a shell filter — both matter, for reasons the next paragraph
gives:

```bash
sudo awk -F: '$3>=500 {print $1, $6, $7}' /etc/passwd \
  | while read -r u h s; do
      if sudo test -s "$h/.ssh/authorized_keys"; then k=has-key; else k=no-key; fi
      printf '%-16s %-10s %-18s %s\n' "$u" "$k" "$s" "$h"
    done
```

On the primary, **13 accounts already have one.** The escalation is not
hypothetical there; it is a path that is already built and only needs a private
key. `accounts/authorized-keys` in the audit reports this as counts.

Filtering by login shell would have said 12 and been wrong. DirectAdmin's
`admin` holds two keys and has no login shell, so it is invisible to a
shell-filtered scan — and `nologin` blocks only the interactive session, not
`ssh -N -L` port forwarding or `sftp` where the subsystem is enabled. That is
why the shell is *printed* here rather than used to exclude anything.

### Triage before you conclude anything

Twelve accounts with keys is not twelve incidents. The question is how many
*distinct* keys there are, because that separates one event from twelve:

`ssh-keygen -l` prints `bits fingerprint comment (TYPE)`, so the comment is the
middle of the line, not the last field — and the comment is usually the only
thing that says whose key it is:

```bash
for h in /home/*; do
  f="$h/.ssh/authorized_keys"
  sudo test -s "$f" || continue
  sudo ssh-keygen -l -f "$f" 2>/dev/null | awk -v u="${h##*/}" '
    { c = ""; for (i = 3; i < NF; i++) c = c (c ? " " : "") $i
      printf "%-47s %-14s %-9s %s\n", $2, u, $NF, c }'
done | sort
```

- **One fingerprint repeated across every account** means something templated
  them at once. Check `/etc/skel/.ssh/authorized_keys` — if a key sits there,
  every DirectAdmin account creation is still copying it, and the problem
  regrows — and consider a migration that rsynced `/home` wholesale.
- **A fingerprint you do not recognise** is the finding. Treat it as a possible
  compromise rather than untidiness: note the file's mtime against your
  DirectAdmin and web logs for that account, and do not delete it before you
  have looked.

Mtimes say whether the files arrived together or one at a time:

The glob has to expand inside the privileged shell too. `sudo stat /home/*/...`
expands in the caller's shell, which cannot see through a mode-700 `.ssh` and so
matches nothing:

```bash
sudo sh -c "stat -c '%y  %n' /home/*/.ssh/authorized_keys 2>/dev/null" | sort
sudo ls -la /etc/skel/.ssh/ 2>/dev/null
```

#### What this host turned out to be

Not a compromise. Six distinct keys across 14 accounts, and nine of the files
were written inside the same 250 ms on 2024-01-29 — a script, not an intrusion.
`/etc/skel/.ssh` does not exist, so nothing is seeding new accounts and the
pattern will not regrow. The remaining mtimes are spread over two years and
match ordinary operator activity.

The finding is a different one, and the file count hides it: **two of those six
keys are installed on 13 and 14 accounts respectively.** Either private key is
the entire box. One of them is on `ec2-user`, which makes it almost certainly
the EC2 key pair, copied to every DirectAdmin account. That is what needs
managing — not the number of files, but the blast radius of two keys. The audit
reports it as "the most widely installed of which is on N of them" for exactly
this reason.

Two details worth knowing:

- **`admin` holds two keys and has no login shell**, which is why it is absent
  from the shell-account listing above. `nologin` blocks the interactive session
  and nothing else: `ssh -N -L` port forwarding still works, and so does `sftp`
  where the subsystem is enabled. Do not read a nologin shell as "this key is
  harmless".
- The DSA key on one account is inert — OpenSSH disabled DSA by default in 7.0
  and removed it in 9.8 — so it is dead weight rather than a risk.

The allowlist below is the control either way. It makes a planted key and an
over-shared key inert in one directive, without first having to work out which
of the six are safe to delete. Deleting keys is per-account, needs a decision
each time, and is easy to get wrong; `AllowGroups` is one line with a known
rollback and a confirmed SSM path behind it. Do it in that order.

### Applying it without locking yourself out

`AllowGroups` refuses everyone who is not in the group, including you, the
moment `sshd` reloads. The gate is a **second** session: keep the one you have
open, and never close it until a new one succeeds.

```bash
# 1. Confirm the recovery path first, from your workstation, not the box:
aws ssm describe-instance-information --profile wbat --region us-east-1 \
  --filters Key=InstanceIds,Values=i-0118b8ede80b52ef7 \
  --query 'InstanceInformationList[0].PingStatus'

# 2. Create the group and put the accounts that genuinely need SSH in it:
sudo groupadd -f sshusers
sudo usermod -aG sshusers tellerstec       # repeat for any other real operator

# 3. Verify membership BEFORE writing the directive:
getent group sshusers

# 4. Then the drop-in, alongside the one from step 1:
printf 'AllowGroups sshusers\n' | sudo tee /etc/ssh/sshd_config.d/20-allowgroups.conf
sudo sshd -t                    # GATE: syntax must pass
sudo systemctl reload sshd      # reload keeps existing sessions alive
sudo sshd -T | grep -i allowgroups
```

**Then open a new SSH session from a second terminal.** If it fails, roll back
from the session you kept open. The drop-in is root-owned and reloading `sshd`
is privileged, so every step needs `sudo` — the operator account this procedure
leaves you in cannot do any of it unprivileged, and discovering that mid-lockout
is how a recoverable mistake turns into an SSM-only one:

```bash
sudo rm /etc/ssh/sshd_config.d/20-allowgroups.conf
sudo sshd -t && sudo systemctl reload sshd
```

If you lost both sessions, the SSM session from step 1 is the way back — this is
exactly the failure it exists for.

One DirectAdmin interaction to know about: if you ever grant an account SSH
access through the panel, it must also be in `sshusers`, or the panel will
appear to grant access that `sshd` then refuses. That is a confusing failure to
debug later, so it is worth a note wherever account provisioning is documented.

`PermitRootLogin without-password` is the other SSH warning, and it is a smaller
one — root has no password path, so this only matters if a root key leaks. Set it
to `no` in the same drop-in once you have confirmed nothing automated logs in as
root: `sudo grep -c . /root/.ssh/authorized_keys` and a look at `last root`.

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

### The plaintext mail and FTP ports are now the last password path

`21`, `110` and `143` accept credentials without implicit TLS, and their
TLS-native equivalents (`465`, `993`, `995`) are already open. That reads like
housekeeping, and it was, until the other doors closed. SSH is key-only, 2222 is
off the internet — so mail and FTP are the **only** remaining places where one
of the publicly disclosed account names can be tried with a password. They are
in `TCP_IN` and reachable right now. `LF_FTPD=10`, `LF_POP3D=10` and
`LF_IMAPD=10` rate-limit the attempts, which buys time rather than closing
anything.

Two separate questions, worth not conflating:

1. **Is TLS mandatory, or merely available?** If STARTTLS is optional on `110`
   and `143`, a client that fails to negotiate sends the password in clear over
   the internet. Mandatory is the fix, and it costs nothing but a config change:

```bash
# Dovecot: disable_plaintext_auth = yes means "not without TLS", not "never"
sudo doveconf -n disable_plaintext_auth ssl
sudo grep -rn 'ftp_tls\|ssl_enable\|force_tls' /etc/proftpd.conf /etc/pure-ftpd.conf 2>/dev/null
```

2. **Should the plaintext ports be open at all?** That one is a
   client-compatibility decision rather than a technical one, which is why the
   audit warns instead of failing. Closing `110`/`143` in `TCP_IN` and leaving
   `993`/`995` is the clean end state; FTP is usually the sticking point,
   because customers have clients configured for `21`.

If you do only one thing here, make TLS mandatory. Closing ports can wait for a
customer-communication window; a password crossing the internet in clear cannot
be un-sent.

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
  an `Online` ping is. This is the check that decides whether steps 1 and 4 are
  safe to attempt.
- `exposure/da-panel-sg` — the security group is a control-plane fact and the
  instance cannot read it, so this one skips **permanently** on the box rather
  than for want of `sudo`. It is why an on-host run exits 3 even when nothing is
  wrong. Run the printed command from a workstation to get the verdict.

`ssh/match` is a third check that can skip, but only where root cannot resolve
`sshd -T -C`; on this host it reports `OK` with no `Match` blocks. Address-keyed
blocks cannot be enumerated by probing, so if it warns `ssh/match-coverage`,
read those blocks by hand.

Re-run after any DirectAdmin update — `update_post` hooks are the usual way an
`sshd_config` or jail change gets quietly reverted.

## What this does not fix

Hardening does not un-publish the names, and it does not help if a password is
already weak or reused. Rotating DirectAdmin passwords for the disclosed
accounts is a reasonable follow-up, and unlike the hardening above it needs
coordination with the account holders.
