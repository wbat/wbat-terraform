# Operator change window: fix DirectAdmin Linked IP / lan_ip (vhost catch-all)

Primary only. No `server2` rehearsal. Backups + `nginx -t` gate + revert on failure.

## Status (2026-07-26)

Done on primary (`server.wbat.net` / `i-0118b8ede80b52ef7`):

| Step | Result |
|------|--------|
| Link arrival IP `172.30.0.71` to EIP `44.214.133.234` (`apache=yes`, `dns=no`) | Done |
| Set `lan_ip=172.30.0.71` | Done |
| Retire tellerstech loopback fixer | Done |
| Unlink stale cutover IP `172.30.0.87` + remove eth0 secondary + drop free DA IP object | Done (backup under `/var/backups/da-vhost-listen/unlink87-20260727T004556Z`) |

Primary now matches **server2**’s pattern: one EIP ↔ one AWS private IP only.
`server2` (`34.205.151.236` ↔ `172.30.0.57`) was already clean and needed no change.

`172.30.0.87` was the old primary’s private IP before the 2026-06-30 shrink cutover
(large volume → 200 GB instance). It was never reassigned on the new ENI; leaving it
linked was forgotten cleanup, not required for traffic once `.71` was linked.

## Preflight

1. SSM session to primary (`i-0118b8ede80b52ef7` / `server.wbat.net`).
2. Confirm arrival IP (should be `172.30.0.71`):

```bash
TOKEN=$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4; echo
```

3. Snapshot listens (diff after):

```bash
nginx -T 2>/dev/null | grep -nE '^\s*(listen|server_name)' \
  | tee /root/listen-before-$(date -u +%Y%m%dT%H%M%SZ).txt
```

## Backups

```bash
stamp=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p /var/backups/da-vhost-listen/$stamp
cp -a /usr/local/directadmin/conf/directadmin.conf \
  /usr/local/directadmin/data/admin/ip.list \
  /var/backups/da-vhost-listen/$stamp/
cp -a /usr/local/directadmin/data/admin/ips \
  /var/backups/da-vhost-listen/$stamp/ips
tar -C /etc -czf /var/backups/da-vhost-listen/$stamp/nginx-etc.tgz nginx
tar -C /usr/local/directadmin/data -czf \
  /var/backups/da-vhost-listen/$stamp/users-nginx.tgz \
  --wildcards 'users/*/nginx.conf'
```

## Hand-patch ordering

The tellerstech loopback fixer injects into **generated**
`/usr/local/directadmin/data/users/tellerstec/nginx.conf` and is re-applied by
root cron every 5 minutes (`/home/tellerstec/bin/fix-nginx-loopback-listeners.sh`).
It is **not** in `cust_nginx`.

Before Linked IP rewrite:

1. Comment out or remove the root cron line that runs the fixer.
2. After Linked IP is correct and `nginx -t` passes, a rewrite will drop the
   extra listens; leave the cron disabled. Retire the script once tellerstech
   access confirms no other consumer.

If the fixer cron is left enabled **after** Linked IP adds `.71` server-wide,
the second `listen 172.30.0.71` in tellerstec blocks can fail `nginx -t`.

## Apply (DA-native)

Prefer the reconciler once installed:

```bash
/usr/local/sbin/da-vhost-listen-reconcile.sh --dry-run
/usr/local/sbin/da-vhost-listen-reconcile.sh --enforce
```

Manual equivalent:

```bash
# 1) Register private IP without touching the NIC (if not already in ip.list)
echo "action=ipmanager&type=api&method=POST&command=CMD_API_IP_MANAGER&action=add&ip=172.30.0.71&netmask=255.255.255.0&add_to_device=no&add_to_device_aware=yes" \
  >> /usr/local/directadmin/data/task.queue

# 2) Link arrival IP to EIP; apply to existing domains; keep private IP out of DNS
#    (task.queue linked_ips *add* works on this DA build)
echo "action=linked_ips&ip_action=add&ip=44.214.133.234&ip_to_link=172.30.0.71&apache=yes&dns=no&apply=yes" \
  >> /usr/local/directadmin/data/task.queue

# 3) lan_ip
sed -i 's/^lan_ip=.*/lan_ip=172.30.0.71/' /usr/local/directadmin/conf/directadmin.conf

# 4) Drain queue + synchronous rewrite
/usr/local/directadmin/directadmin taskq --run-all
/usr/local/directadmin/directadmin taskq --run 'action=rewrite&value=httpd'

# 5) Gate
nginx -t && systemctl reload nginx
```

### Unlink a stale Linked IP (do **not** use task.queue delete)

On this DA build, `action=linked_ips&ip_action=delete&...` in `task.queue` is a no-op
(`dataskq: unknown taskq action`). Prefer Admin UI (**IP Management** → EIP → Linked IPs →
remove), **or** the file edit below. Do not proceed to `ip addr del` / reload until the
stale address is gone from `linked_ips` and from `nginx -T`.

```bash
EIP=44.214.133.234
STALE=172.30.0.87   # example: forgotten cutover private IP
KEEP=172.30.0.71    # must remain linked
EIP_FILE=/usr/local/directadmin/data/admin/ips/$EIP

cp -a "$EIP_FILE" "${EIP_FILE}.bak-$(date -u +%Y%m%dT%H%M%SZ)"

# Rewrite linked_ips to KEEP only (DA stores IP percent-encoded; '=' before flags stays).
python3 - <<PY
import pathlib, urllib.parse
path = pathlib.Path("$EIP_FILE")
keep, stale = "$KEEP", "$STALE"
text = path.read_text().splitlines()
enc = urllib.parse.quote(keep, safe="") + "=" + urllib.parse.quote("apache=yes&dns=no", safe="")
out = []
for line in text:
    if line.startswith("linked_ips="):
        out.append("linked_ips=" + enc)
    else:
        out.append(line)
path.write_text("\\n".join(out) + "\\n")
raw = urllib.parse.unquote(enc)
assert keep in raw and stale not in raw, raw
print("linked_ips now:", raw)
PY
chown diradmin:diradmin "$EIP_FILE"
chmod 600 "$EIP_FILE"

/usr/local/directadmin/directadmin taskq --run 'action=rewrite&value=httpd'

# Gate: configs must no longer listen on STALE before touching the NIC / reload.
count=$(nginx -T 2>/dev/null | grep -c "listen ${STALE}" || true)
if [ "$count" -ne 0 ]; then
  echo "ERROR: still $count listen lines for $STALE — aborting (restore $EIP_FILE.bak-*)" >&2
  exit 1
fi

ip addr del "${STALE}/24" dev eth0 2>/dev/null || true
# If the stale IP is status=free and not in ip.list:
#   mv /usr/local/directadmin/data/admin/ips/$STALE /var/backups/da-vhost-listen/
nginx -t && systemctl reload nginx
```

## Validate

```bash
/usr/local/sbin/nginx-vhost-listen-invariant.sh --arrival 172.30.0.71
./aws/docs/check-vhost-listeners.sh --ports 80,443 --acme \
  tellerstech.com origin.tellerstech.com iots.com lmgt.com
```

Confirm `www.tellerstech.com` still 200 through CloudFront and
`origin.tellerstech.com` still 403 without the secret header.

## Catch-all detector header

Hostname vhosts (`/etc/nginx/nginx-vhosts.conf`, persisted under
`custombuild/custom/nginx/conf/nginx-vhosts.conf`) emit
`X-DA-Catchall: 1` on `/` for unmatched hosts. Real domain vhosts must not.
Allowlist `server.wbat.net` in checkers.

## ACME / Let's Encrypt

DA serves HTTP-01 from the **shared** root `/var/www/html/.well-known/acme-challenge`
(via `webapps.conf`), not each domain docroot. Force-SSL redirects on `:80` 301 to
HTTPS; challenges still succeed over HTTPS on that shared path. Certs for
`iots.com` / `lmgt.com` were valid through **2026-08-22** at fix time — no forced
renewal required once vhost matching is restored.

## Rollback

```bash
# restore backups from /var/backups/da-vhost-listen/<stamp>
# (for the .87 unlink specifically: unlink87-20260727T004556Z)
# restore EIP linked_ips / lan_ip / ips/* as needed, rewrite, nginx -t, reload
/usr/local/directadmin/directadmin taskq --run 'action=rewrite&value=httpd'
nginx -t && systemctl reload nginx
```
