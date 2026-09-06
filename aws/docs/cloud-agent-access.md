# Giving a Cloud Agent visibility

An agent working in this repo can always do the offline loop — `terraform fmt`,
`init -backend=false`, `validate`. It cannot see anything about the running system:
no metrics, no logs, no plans, no shell. This document sets up the three access paths
that fix that, in increasing order of privilege.

Everything here is opt-in and independently revocable. `.cursor/start.sh` reports which
paths are live at boot and continues without the ones that are not, so a partial setup
still yields a working agent.

## What an agent can do with each path

| Path | Grants | Credential | Revoke by |
| --- | --- | --- | --- |
| AWS read-only | Metrics, logs, describes, cost | `cursor-agent` IAM key | Deleting the access key |
| AWS Session Manager | Root-equivalent shell on both EC2 boxes | same key | `cursor_agent_shell_access = false` |
| HCP Terraform | Read plans, runs, state outputs | API token | Revoking the token |
| Tailscale | SSH over the tailnet | ephemeral auth key | Revoking the key / ACL |

## Prerequisite: allow secrets on a public repository

`wbat/wbat-terraform` is public, and Cursor **disables secret injection for public
repositories by default**. Adding secrets without changing that setting produces an
agent where every variable is unset and every check in the start log reports "unset" —
which looks like a broken setup rather than a policy decision.

In the Cursor dashboard, under Cloud Agents settings, explicitly allow secrets for this
repository before adding any of the values below. Prefer **repo-scoped** secrets over
user- or team-wide ones so these credentials reach only agents working on this repo.

## 1. AWS (metrics, logs, data, and shell)

`aws/global/iam/user-CursorAgent.tf` defines a `cursor-agent` IAM user with two
policies: a read-only telemetry policy, and a Session Manager policy gated behind
`local.cursor_agent_shell_access`.

Read the policy before applying. The parts worth understanding:

- **It cannot change anything.** Read verbs only — no `Create`, `Modify`, `Delete`, or
  `Put` on any service. Infrastructure changes still require a PR and an HCP Terraform
  apply.
- **It cannot read customer data or secrets.** An explicit `Deny` covers `s3:GetObject`,
  `secretsmanager:GetSecretValue`, and `kms:Decrypt`. That deny survives someone later
  attaching a broad managed policy, because an explicit deny always wins in IAM
  evaluation. Without it, "read-only" would include every hosted site's files and
  databases in the DirectAdmin backup bucket.
- **The shell is the real grant.** `ssm:StartSession` lands as `ssm-user`, which the SSM
  agent gives passwordless sudo. On the primary that is root on the box serving ~91
  WordPress sites. It is scoped by `Name` tag to the two known instances and every
  session is recorded in CloudTrail, but it is still root. If that is more than you
  want, set `cursor_agent_shell_access = false` and keep the telemetry half.

Session Manager is preferred over an SSH key because it needs no inbound port, no
security-group change, and no private key on the agent VM — and the instance profile
already carries `AmazonSSMManagedInstanceCore`, so nothing changes on the servers.

### Steps

1. Merge and apply the PR that adds `user-CursorAgent.tf`.
2. Create the key (it is deliberately not Terraform-managed, so the secret never lands
   in HCP Terraform state):

   ```bash
   aws iam create-access-key --user-name cursor-agent --profile wbat
   ```

3. Paste into Cursor secrets, then discard the local output:
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`

   Region is not a secret; `.cursor/install.sh` writes `us-east-1` into `~/.aws/config`.

### Verify

A new agent's start log should show `OK aws credentials valid: arn:aws:iam::…:user/cursor-agent`.
Then, from an agent:

```bash
# Both instances should report the SSM agent Online
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,IPAddress]' --output table

# Shell (requires cursor_agent_shell_access = true)
aws ssm start-session --target "$(aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=WBAT Primary Server' \
            'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"

# Proof the deny works — this must fail with AccessDenied
aws secretsmanager get-secret-value --secret-id tellerstech/ses-gmail-forward/runtime-config
```

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

## 3. Tailscale (SSH over the tailnet)

Only needed if you want SSH specifically. If AWS Session Manager is set up, an agent
already has shell access to both boxes and this path is redundant.

This requires Tailscale to be **installed and running on the servers**. The usual admin
route into the primary is public DNS with an SSH key, which does not imply the boxes are
on a tailnet — confirm before setting this up.

Cloud Agent VMs cannot use a TUN interface, so `.cursor/start.sh` runs `tailscaled` in
userspace-networking mode with a SOCKS5/HTTP listener on `127.0.0.1:1055`, and
`.cursor/install.sh` writes an `~/.ssh/config` that proxies tailnet hosts through
`tailscale nc`. Plain `ssh` to a tailnet name works as a result; `ssh` to a public
address is unaffected.

### Steps

1. In the Tailscale admin console, generate an auth key that is:
   - **Ephemeral** — the node is removed automatically when the agent VM goes away,
     instead of accumulating dead nodes on every run.
   - **Pre-approved** — otherwise each new agent waits for manual device approval.
   - **Tagged**, e.g. `tag:cursor-agent`, so ACLs target the tag rather than a device.
2. Add it as the secret `TS_AUTHKEY`.
3. Write an ACL granting that tag only what it needs — SSH to the two servers, nothing
   else. Enable Tailscale SSH on the servers so no private key has to be distributed to
   the agent VM. Do not put an SSH private key in a Cursor secret if this can be avoided;
   Tailscale SSH authenticates the node's tailnet identity instead.

Note that auth keys expire (90 days maximum). When one does, the start log reports
`WARN tailscale up failed` and the agent falls back to SSM rather than losing all access.

### Verify

```bash
tailscale status              # agent node present, tagged
ssh <user>@<server-tailnet-name> 'hostname -f'
```

## Recommendation

Set up **AWS** and **HCP Terraform** first: together they cover metrics, logs, data,
plans, and shell, with no changes on the servers. Add Tailscale only if you want SSH for
its own sake.

If you want the smallest useful grant, start with `cursor_agent_shell_access = false`.
That gives full read-only visibility — enough to investigate almost everything in
`aws/docs/` — while keeping interactive access to the production web server a
human-in-the-loop action.
