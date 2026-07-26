# Known-bad fixture: nginx catch-all vhost regression

Captured **2026-07-26T21:55:13Z** from primary `i-0118b8ede80b52ef7`
(`server.wbat.net`) via SSM **before** any Linked-IP / reconciler changes.

Use this as the offline known-bad input for the nginx `-T` invariant parser
(`prove-detector` / static invariant). Do not “fix” these files in place —
regenerate a new fixture after the change window if a post-fix baseline is
needed.

## Confirmed broken state

| Fact | Value |
|------|-------|
| Arrival / IMDS local IPv4 | `172.30.0.71` |
| EIP on eth0 | `44.214.133.234/32` |
| Stale secondary on eth0 | `172.30.0.87/24` |
| `lan_ip` in `directadmin.conf` | `172.30.0.87` (wrong) |
| Linked IP on EIP | only `172.30.0.87` (`apache=yes&dns=no`) |
| Web stack | nginx `1.31.2`, PHP 8.2 default |

**Listen asymmetry (the bug):**

- Most domain server blocks: `listen 44.214.133.234` + `listen 172.30.0.87` only.
- `tellerstech.com` / related tellerstec vhosts also have `127.0.0.1`, `[::1]`,
  and `172.30.0.71` injected by the hand-patch.

Public traffic NAT’s to `.71`, so only the patched tellerstec vhosts match;
everything else falls to the catch-all (`CN=server.wbat.net`).

## Hand-patch injection site

Not in `cust_nginx` / custombuild nginx templates (none present). Injects into
the **generated** user config and is re-applied from cron:

- Script: `/home/tellerstec/bin/fix-nginx-loopback-listeners.sh`
- Also shipped under the WP plugin tree:
  `.../plugins/tellerstech-landing/scripts/fix-nginx-loopback-listeners.sh`
- Target: `/usr/local/directadmin/data/users/tellerstec/nginx.conf`
- Cron (root, every 5 min): runs the bin script with a healthchecks.io ping URL

Because it edits generated `nginx.conf`, a DA rewrite wipes it until cron
re-injects — and the inject is tellerstec-only, which is how the catch-all
regression appeared for every other domain.

## Files

| File | Purpose |
|------|---------|
| `nginx-T.full.txt` | Full `nginx -T` (known-bad) |
| `nginx-T.listen-server_name.txt` | Compact `listen` / `server_name` grep |
| `directadmin.conf.relevant.txt` | `lan_ip`, nginx flags, servername |
| `ip.list` / `ips/*` | DA IP manager + linked_ips |
| `ip-addr.txt` / `imds-*.txt` | Host + IMDS addressing |
| `user-nginx-loopback-hits.txt` | Where `.71` / `127.0.0.1` listens appear |
| `hand-patch-search.txt` | Custom scripts / path search at capture time |
| `domainowners.txt` | Domains on the box |
| `custombuild-options-web.txt` | CustomBuild web stack options |

## SHA-256 of capture tarball

`9b25d480e1fa6679fa4082517ff2a48eed617855daaf8487b484f85081b836c7`
(/tmp on instance at capture time)
