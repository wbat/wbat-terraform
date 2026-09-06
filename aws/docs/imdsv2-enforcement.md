# IMDSv2 enforcement

Current state, which is deliberately asymmetric:

| | `http_tokens` | Why |
| --- | --- | --- |
| Secondary instance + launch template | `required` | Flat zero IMDSv1 use across 14 days |
| Primary instance + launch template | `optional` | Installatron's updater still calls IMDSv1 — see below |

## Why it matters more than usual here

IMDSv1 answers an unauthenticated `GET`. That is what converts a server-side request
forgery in *any* hosted application into a set of instance-role credentials — the
classic path being a WordPress plugin that fetches a user-supplied URL. IMDSv2 requires a
`PUT` to obtain a token first, which same-origin browser requests and most SSRF primitives
cannot perform, and the token request is rejected at a hop limit of 1.

The blast radius on these boxes is not theoretical:

- Roughly 91 WordPress sites share the primary, each with its own plugin surface.
- Both instances share the `WBAT_Main_Server` instance profile, so the secondary is
  equally exposed despite only serving DNS. That is why it enforces.
- That profile can send SES mail and create CloudFront invalidations. Stolen credentials
  mean spam sent as the domain, and cache invalidation against the CDN.

## Why the primary does not enforce

`http_tokens = "required"` is applied through `ModifyInstanceMetadataOptions`. It takes
effect **immediately, with no reboot, and with no grace period**. Anything still calling
IMDSv1 starts receiving `401 Unauthorized` the moment the apply lands.

On the primary, something still is: **Installatron's auto-updater**.

```
/etc/cron.d/installatron
33 1,7,13,19 * * * root /usr/local/installatron/lib/cron.updater.sh
```

which runs `/usr/local/installatron/repair -f`. The box is on `America/New_York`, so those
local hours land at 05:33, 11:33, 17:33, and 23:33 UTC.

What was measured over the 7 days to 2026-09-06, from `MetadataNoToken` on the primary:
**27 non-zero 5-minute buckets, 192 requests, and every one of the other 1,989 buckets
zero.** Six requests per burst, four bursts a day, six hours apart, except the 05:33 UTC
burst which is always nine — that is the once-a-day run where Installatron's task
scheduler also walks the hosted WordPress sites.

Three things pin it to Installatron rather than merely correlating with it:

- **It is the only 6-hourly schedule on the machine.** `systemctl list-timers --all`,
  `/etc/crontab`, all of `/etc/cron.d/`, and all 18 crontabs in `/var/spool/cron/` were
  enumerated. Replaying `/var/log/cron` for minute `:33` returns `cron.updater.sh` and
  nothing else.
- **The runs and the bursts match one-for-one, including a miss.** Installatron's own log
  (`/var/installatron/logs/repair_crontab_log`) records 27 runs in that window against 27
  non-zero buckets. On 2026-09-06 the 07:33 EDT run never happened because the box was
  down, and 11:30 UTC is the one empty bucket in the whole week.
- **That same reboot rules out a daemon.** A process with an internal 6-hour timer would
  have re-phased after booting at 09:13 EDT. The next burst still landed at 13:33, in the
  original phase, so the trigger is wall-clock cron.

Everything else was excluded. `amazon-ssm-agent`, `nm-cloud-setup`, the AWS CLI, `boto3`,
W3 Total Cache's bundled `aws-sdk-php`, WordPress cron, and our own
`da_vhost_listen_reconcile.sh` are all token-first — several confirmed on the wire doing
`PUT /latest/api/token` first. The cleanest evidence is the differential: the secondary runs
the *same* SSM agent, AWS CLI, OS, timezone, DirectAdmin, and `da-vhost-listen` cron, has no
Installatron, and is flat zero.

### What has to happen before the primary can enforce

Installatron is ionCube-encoded vendor code, already on the `edge` channel at the latest
version. There is no SDK to bump and no script to add a token fetch to, so this is a vendor
request, not a local change. Two options:

1. Ask Installatron to make its metadata reads IMDSv2-native. Worth capturing the exact
   paths it requests first (below) so the report is specific. There is a reasonable chance
   it is cloud detection or public-IP discovery for IP-based licensing — if so it may
   already have a fallback, since `44.214.133.234` is configured directly on `eth0` and
   appears in DirectAdmin's `ip.list`. That is inference, not verified.
2. Retire Installatron.

Then flip `http_tokens` to `"required"` in both `primary-instance.tf` and
`primary-launch_template.tf` — they are one word each, and the instance's current
`"optional"` is declared explicitly so the diff is obvious.

## Re-checking the pre-flight

Before enforcing on either box, confirm `MetadataNoToken` is flat at zero:

```bash
for id in $(cd aws && terraform output -raw primary_instance_id) \
          $(cd aws && terraform output -raw secondary_instance_id); do
  echo "=== $id ==="
  aws cloudwatch get-metric-statistics --profile wbat \
    --namespace AWS/EC2 \
    --metric-name MetadataNoToken \
    --dimensions Name=InstanceId,Value="$id" \
    --start-time "$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 86400 \
    --statistics Sum \
    --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Sum]' \
    --output text
done
```

Reading the result:

- **No datapoints, or every `Sum` is `0`** — nothing has used IMDSv1 in two weeks. Safe
  to apply.
- **Any non-zero `Sum`** — something is still on v1. Do **not** apply until it is found,
  or it breaks on apply.

Two things to know about this metric. It counts *requests*, not distinct callers, so a burst
of six is consistent with one script making six reads. And **detailed monitoring is disabled
on both instances**, so 1-minute resolution does not exist — a `--period 60` request
silently returns 5-minute buckets. "05:33" is really "the bucket covering 05:30–05:34".

## Identifying a v1 caller

If a *new* one appears, do not run the capture blind. Start it just before a burst you have
already located with `--period 300`, and attribute the connection to a process:

```bash
# Run a minute before a known burst; 05:33 or 23:33 UTC for the Installatron job
timeout 300 tcpdump -nn -A -s0 'dst 169.254.169.254 and tcp port 80' > /tmp/imds.txt &
timeout 300 bash -c 'while :; do ss -Htnp dst 169.254.169.254 >> /tmp/imds-pids.txt; sleep 0.2; done'

# Requests with no token header are the v1 ones
grep -B2 -A8 'GET /latest' /tmp/imds.txt | grep -v 'X-aws-ec2-metadata-token'
```

Note that a text search of the caller's own files may prove nothing: grepping
`/usr/local/installatron` for `169.254.169.254` finds no match because the PHP is bytecode.
Absence of a string is not absence of the behaviour.

Our own tooling is already v2-native and will not appear:
`scripts/directadmin/da_vhost_listen_reconcile.sh` obtains a token via
`PUT /latest/api/token` before every metadata read, and the diagnostic snippets in
[nginx-vhost-catchall-regression.md](nginx-vhost-catchall-regression.md) and
[da-vhost-listen-change-window.md](da-vhost-listen-change-window.md) do the same.

## Verifying after apply

Run this on whichever box you just enforced on:

```bash
# v1 must now be refused
curl -s -o /dev/null -w '%{http_code}\n' \
  http://169.254.169.254/latest/meta-data/local-ipv4          # expect 401

# v2 must still work
TOKEN=$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4; echo    # expect the private IP

# The reconciler depends on IMDS for arrival-IP detection, so prove it still agrees
/usr/local/sbin/da-vhost-listen-reconcile.sh --check; echo "exit=$?"
```

A reconciler run that reports `arrival=` correctly is the signal that matters: if IMDS
were unreachable it would fall back or fail, and the vhost invariant is what keeps every
domain bound to its own server block.

## Rolling back

Set `http_tokens = "optional"` on the affected instance and apply. It reverts as
immediately as it applied, again with no reboot. Prefer this over debugging under
pressure — then find the v1 caller with the capture above and re-enforce.

## A note on hop limit

`http_put_response_hop_limit = 1` is already the live setting on both instances, so pinning
it in Terraform is a no-op rather than a behavioural change. It is also the right value:
the only v1 caller found is a root cron job invoking a local binary, and no container
runtime is present on either box. It would need to be `2` only if something reached IMDS
from inside a container.
