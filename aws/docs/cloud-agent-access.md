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
| AWS read-only | Metrics, logs, describes, cost | `cursor-agent` IAM key | Deleting the access key |
| AWS Session Manager | Root-equivalent shell on both EC2 boxes | same key | `cursor_agent_shell_access = false` |
| HCP Terraform | Read plans, runs, state outputs | API token | Revoking the token |

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
- **Sessions are attributable.** Every `StartSession` is a CloudTrail event tied to the
  `cursor-agent` user, and access is revoked by deleting one access key.

Tailscale and the `.pem` key remain the **human** paths, and they are the fallback if the
SSM agent on a box ever stops reporting — a case `.cursor/start.sh` reports at boot.
`AWS-StartSSHSession` is deliberately excluded from the IAM policy: it tunnels real SSH
over SSM and would still require a private key on the VM.

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
expected to work here. If a fresh agent's start log nevertheless reports every value
"unset", suspect that restriction rather than a broken key, and check the scope the
secret was created under.

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

`cursor_agent_shell_access = true` (the default in the PR that added this) gives full
visibility plus shell. `false` gives read-only telemetry — enough to investigate almost
everything documented under `aws/docs/` — while keeping interactive access to the
production web server a human-in-the-loop action.

Worth knowing when deciding: the shell is root-equivalent, and it is the only part of
this setup that can change the running system. Everything else is constrained by IAM to
reads.
