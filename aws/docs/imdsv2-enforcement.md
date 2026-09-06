# IMDSv2 enforcement

Both instances and both launch templates set `http_tokens = "required"`, which turns off
unauthenticated IMDSv1 access to `169.254.169.254`.

## Why it matters more than usual here

IMDSv1 answers an unauthenticated `GET`. That is what converts a server-side request
forgery in *any* hosted application into a set of instance-role credentials — the
classic path being a WordPress plugin that fetches a user-supplied URL. IMDSv2 requires a
`PUT` to obtain a token first, which same-origin browser requests and most SSRF primitives
cannot perform, and the token request is rejected at a hop limit of 1.

The blast radius on these boxes is not theoretical:

- Roughly 91 WordPress sites share the primary, each with its own plugin surface.
- Both instances share the `WBAT_Main_Server` instance profile, so the secondary is
  equally exposed despite only serving DNS.
- That profile can send SES mail and create CloudFront invalidations. Stolen credentials
  mean spam sent as the domain, and cache invalidation against the CDN.

## The one thing to check before applying

`http_tokens = "required"` is applied through `ModifyInstanceMetadataOptions`. It takes
effect **immediately, with no reboot, and with no grace period**. Anything still calling
IMDSv1 starts receiving `401 Unauthorized` the moment the apply lands.

EC2 publishes a metric that counts exactly those calls. Check it on both instances and
only proceed if it is flat at zero:

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
  or it breaks on apply. Note that a low, steady count is often a monitoring agent or an
  old SDK rather than anything user-facing.

`MetadataNoToken` is a count of *requests*, not of distinct callers, so it tells you
whether v1 is in use but not by whom. To identify the caller, run this on the box while
watching the number:

```bash
# IMDS traffic with no token header, by process
sudo tcpdump -nn -A -s0 'dst 169.254.169.254 and tcp port 80' 2>/dev/null \
  | grep -B2 -A8 'GET /latest' | grep -v 'X-aws-ec2-metadata-token'
```

Our own tooling is already v2-native and will not appear:
`scripts/directadmin/da_vhost_listen_reconcile.sh` obtains a token via
`PUT /latest/api/token` before every metadata read, and the diagnostic snippets in
[nginx-vhost-catchall-regression.md](nginx-vhost-catchall-regression.md) and
[da-vhost-listen-change-window.md](da-vhost-listen-change-window.md) do the same.

## Verifying after apply

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
pressure — then find the v1 caller with the `tcpdump` above and re-enforce.
