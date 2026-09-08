# Giving a Cloud Agent visibility

An agent working in this repo can always do the offline loop — `terraform fmt`,
`init -backend=false`, `validate`. It cannot see anything about the running system:
no metrics, no logs, no plans, no shell. This document sets that up.

It takes **two credentials**: an AWS key and an HCP Terraform token. Both are opt-in and
independently revocable, and `.cursor/start.sh` reports which are live at boot, so a
partial setup still yields a working agent.

## What an agent gets

| Path | Grants | Credential | Revoke by |
| --- | --- | --- | --- |
| AWS | Whatever `bteller` can do — currently admin | `bteller` IAM key | Deactivating that key (see §1) |
| AWS Session Manager | Root-equivalent shell on both EC2 boxes | same key | Same — plus ending any live session |
| HCP Terraform | Read plans, runs, state outputs | API token | Revoking the token |

Revoke at the source, not in the dashboard. Secrets are injected into an agent's
environment **at process start**, so deleting a secret only changes what the *next* agent
receives — a run already in flight keeps its copy of the credential and its shell.
Deactivating the IAM key or revoking the HCP token takes effect immediately for every
caller, running agents included. Delete the dashboard secret as well so the next agent
does not pick it back up, and terminate active runs if you need the shell closed now.

The AWS row is deliberately blunt. This setup currently reuses a human admin key rather
than a scoped agent identity, so the honest description of the grant is "everything."
§1 covers what that costs and how to narrow it later.

## Why not SSH

Both servers are on the tailnet and both accept a `.pem` key, so SSH is possible. It is
deliberately not wired into agents, because Session Manager provides the same shell with
strictly less standing credential:

- **No key material on the agent VM.** SSH needs either the `.pem` private key or a
  Tailscale node identity. Session Manager authenticates with the same IAM credential
  already needed for metrics, so shell access adds no new secret.
- **Nothing expires on its own.** Tailscale auth keys last 90 days at most, so that path
  breaks quarterly and always at the moment access is wanted.
- **Nothing changes on the servers.** The instance profile already carries
  `AmazonSSMManagedInstanceCore`. No inbound port, no security-group edit, no tailnet
  node per agent VM.
- **Sessions are logged.** Every `StartSession` is a CloudTrail event. Note that while
  the agent uses `bteller`'s key those events carry the *human's* identity, so the log
  tells you a session happened but not who opened it — see §1.

Tailscale and the `.pem` key remain the **human** paths, and they are the fallback if the
SSM agent on a box ever stops reporting — a case `.cursor/start.sh` reports at boot.
`AWS-StartSSHSession` is deliberately excluded from the IAM policy: it tunnels real SSH
over SSM and would still require a private key on the VM.

## First: the environment has to be saved, not just committed

Committing `.cursor/environment.json` is **not** what creates the environment. It is the
proposed config; the environment exists only once it is saved from the dashboard. An agent
that starts before that runs with *no linked environment*, and then:

- `install.sh` and `start.sh` never execute. Nothing writes `/tmp/cursor/start-user/`, so
  there is no start log to read, and no `terraform`, `aws`, or `session-manager-plugin`
  unless the base image happens to ship them.
- **No secrets are injected at all**, whatever scope they were created under.

This was observed rather than inferred: an agent on the branch that added these files
reported all three values unset, with `/tmp/cursor` absent, while the committed
`environment.json` sat right there in its own checkout. The tooling was present only
because an earlier turn had run `install.sh` by hand.

So if a fresh agent reports every credential unset, check this before suspecting the keys.
The distinguishing symptom is the **absence of a start log**: a linked environment always
produces `/tmp/cursor/start-user/start-user.log`, and `start.sh` names each missing
credential in it. No log at all means the environment never ran, which is a different
problem from a credential that did not arrive.

## Where the secrets go

[cursor.com/dashboard/cloud-agents](https://cursor.com/dashboard/cloud-agents) → the
**Secrets** tab. That is the only documented location; there is no equivalent in the
desktop IDE. If the tab is not visible, it is an account-permissions matter.

**Scope.** There is no per-repository secret type. Secrets are user-, team-, or
environment-scoped, and an *environment* can be scoped to a single repo — so an
environment-scoped secret on a single-repo environment is how you get "only agents
working on this repo." That is the right choice for these three values, since neither
credential has any use outside this repository. Note that precedence between scopes for
the same variable name is not documented, so avoid defining the same name twice.

**Type**, which controls exposure rather than reach:

| Value | Type | Why |
| --- | --- | --- |
| `AWS_ACCESS_KEY_ID` | Environment Variable | The non-secret half of the pair — AWS itself surfaces key IDs in CloudTrail and error messages. Leaving it visible makes a credential mix-up diagnosable instead of guesswork. |
| `AWS_SECRET_ACCESS_KEY` | Runtime Secret | Redacted from tool results, transcripts, and commit messages. |
| `TF_TOKEN_app_terraform_io` | Runtime Secret | Same. |

Do not use **Build Secret** for any of these: that type is exposed only to the Docker
build and not to the running agent, which is the reverse of what is needed here.

**Timing.** Secrets are injected as environment variables when an agent *starts*. An
already-running agent will never see a newly added secret, so start a fresh agent to
test. Changing an environment's secrets also triggers a new build.

`.cursor/install.sh` deliberately needs no credentials, which sidesteps a sharp edge
here: user-scoped secrets are not available during builds (where `install` runs), only
team- and environment-scoped ones are. Everything that reads a credential lives in
`start.sh`, which runs per boot with all runtime secrets present.

**On this repo being public:** the only documented public-repository secret restriction
applies to per-run environment variables passed through the SDK, not to dashboard
secrets, and there is no documented toggle to change it. So dashboard secrets are
expected to work here. If a fresh agent's *start log* reports every value "unset" —
meaning the environment did run, so the section above is not the cause — suspect that
restriction rather than a broken key, and check the scope the secret was created under.

## 1. AWS (metrics, logs, data, and shell)

**Current choice: reuse the existing `bteller` admin key.** No new IAM identity is
created, so there is nothing here for Terraform to apply — `bteller` is a console-managed
user and does not appear in this repo. Setup is entirely a dashboard operation.

That keeps setup to one step, and it is a reasonable call for a single-operator account
where the agent is already trusted. It is worth being precise about what it gives up,
because three things in this document would otherwise read as guarantees that no longer
hold:

- **The agent is an admin.** There is no read-only boundary and no explicit `Deny` on
  `s3:GetObject`, `secretsmanager:GetSecretValue`, or `kms:Decrypt`. An agent can read
  every hosted site's files and databases in the DirectAdmin backup bucket, read secret
  values, and change or delete infrastructure directly — bypassing the PR-and-HCP-apply
  path that otherwise gates every change. Treat the constraint as *trust and review*, not
  as IAM enforcement.
- **CloudTrail cannot tell the agent from you.** Both act as `bteller`, so an unexpected
  API call cannot be attributed without correlating timestamps against agent transcripts.
  This is the loss that is hardest to reconstruct after the fact, and the main reason to
  revisit the decision if a second person ever touches the account.
- **Revocation is coarse, and the obvious move does not work.** Deleting the dashboard
  secret feels like revocation but only affects agents that start afterwards; a running
  agent already holds the credential in its environment and keeps both admin API access
  and its root shell. Real revocation is `aws iam update-access-key --status Inactive`,
  which cuts every caller at once — and because this is `bteller`'s key rather than a
  dedicated one, that also breaks the human profiles using it. In an emergency take the
  breakage: deactivate the key, delete the secret so the next agent cannot pick it up,
  terminate live runs, then issue yourself a fresh key.

The shell grant is unchanged in kind but no longer scoped: `ssm:StartSession` lands as
`ssm-user` with passwordless sudo, on the primary that is root on the box serving ~91
WordPress sites, and admin credentials can target any instance rather than the two
tagged ones.

### Steps

1. Nothing to merge or apply. Use the existing `bteller` access key, or mint a fresh one
   for this purpose so it can be rotated without disturbing the working local profile:

   ```bash
   aws iam create-access-key --user-name bteller --profile wbat
   ```

   A separate key on the same user does not fix attribution — CloudTrail still records
   `bteller` — but it makes revocation cheap, which is the more common need: an agent-only
   key can be deactivated instantly without taking your own CLI down with it. That turns
   the emergency path below from disruptive into routine, so it is worth the extra minute.

2. Paste into Cursor secrets, then discard the local output:
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`

   Region is not a secret; `.cursor/install.sh` writes `us-east-1` into `~/.aws/config`.

Because this repo is public, confirm secret injection is permitted for public
repositories in the dashboard — it can be disabled by default, and the symptom is an
agent whose environment ran but whose credentials are simply absent.

### Verify

A new agent's start log should show `OK aws credentials valid: arn:aws:iam::…:user/bteller`.
Then, from an agent:

```bash
# Both instances should report the SSM agent Online
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,IPAddress]' --output table

# Shell
aws ssm start-session --target "$(aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=WBAT Primary Server' \
            'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
```

Note what is *not* here: the previous version of this runbook ended with a command
asserting that reading a secret fails with `AccessDenied`. Under an admin key it
succeeds, so the check was removed rather than left to pass misleadingly.

### Narrowing this later

A scoped, read-only `cursor-agent` IAM user was written and reviewed for this purpose,
then set aside in favour of the simpler path above. It grants telemetry plus a
tag-scoped Session Manager shell, denies data and secret reads, and cannot apply
changes. Restoring it is a file copy, not a rewrite:

```bash
git show cf36e75:aws/global/iam/user-CursorAgent.tf > aws/global/iam/user-CursorAgent.tf
```

That blob lives on the branch behind PR #115; fetch `refs/pull/115/head` first if the
branch is gone. Then apply, mint a key for `cursor-agent`, and swap the two secrets.
The rest of this document needs no changes — only the three caveats above stop applying.

## 2. HCP Terraform (reading plans)

Create a token in HCP Terraform and add it as the secret **`TF_TOKEN_app_terraform_io`**.
The exact name matters: the Terraform CLI consumes that variable natively for the
`app.terraform.io` backend, so `terraform plan` and `terraform show` work with no
`~/.terraformrc` to write, and the same value serves as the API bearer token for reading
run and plan JSON.

Prefer a **team token** scoped to read-only on the three workspaces over a personal user
token. A user token carries your full HCP Terraform identity across every organization
you belong to; a team token carries only what that team can see, and revoking it does
not disrupt your own access.

Note that a token which can queue a plan can generally also queue an apply if the
workspace permits it. Read-only team access is what keeps "view plans" from becoming
"change infrastructure".

### Verify

Start log shows `OK terraform cloud token valid` for a user token, or
`NOTE … expected for a team token` for a team token. A revoked or expired token reports
`WARN … rejected (401)` rather than passing silently.

```bash
curl -sS -H "Authorization: Bearer $TF_TOKEN_app_terraform_io" \
  'https://app.terraform.io/api/v2/organizations/<org>/workspaces' \
  | jq -r '.data[].attributes.name'
```

## If the SSM agent stops reporting

This is the one failure mode that costs an agent its shell, so it is worth recognising.
`.cursor/start.sh` logs `WARN no instance reports an Online SSM agent` at boot, and
`aws ssm start-session` fails with `TargetNotConnected`.

Telemetry is unaffected — metrics, logs, and describes all keep working, because they
never touch the box. To restore the shell, connect over Tailscale or with the `.pem` key
and check the agent:

```bash
systemctl status amazon-ssm-agent
sudo systemctl restart amazon-ssm-agent
```

The usual causes are the service being stopped, the instance losing its instance profile,
or egress to the `ssm`, `ssmmessages`, and `ec2messages` endpoints being blocked.

## Choosing how much to grant

With an admin key there is no dial: the agent has everything, and the only lever is
whether the AWS secret is present in the environment at all. Removing it leaves the HCP
Terraform token, which still supports reading plans and state outputs — a genuinely
useful read-only mode for reviewing changes, just not for diagnosing the running system.

The finer-grained choice — telemetry with or without a shell, and no ability to change
anything — comes back with the scoped user described under **Narrowing this later**.
That is the version to reach for if a second person gets account access, if an agent
ever needs to run unattended, or if you want CloudTrail to distinguish agent activity
from your own.
