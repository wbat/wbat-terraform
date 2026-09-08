# Known-bad fixture: nginx catch-all vhost regression

Captured **2026-07-26T21:55:13Z** from primary `i-0118b8ede80b52ef7`
(`server.wbat.net`) via SSM **before** any Linked-IP / reconciler changes.

Use this as the offline known-bad input for the nginx `-T` invariant parser
(`prove-detector` / static invariant). Do not “fix” these files in place —
regenerate a new fixture after the change window if a post-fix baseline is
needed.

## Sanitised

This repository is public, so the capture is **not** verbatim. Hosted domain
names, DirectAdmin account names, and package versions have been replaced with
placeholders. Everything the parser is tested on is untouched: listen
addresses, `server_name` shape (apex plus `www`), block nesting, and the
asymmetry between hand-patched and unpatched vhosts. Line counts and per-address
`listen` counts match the original exactly.

| Real value | Appears here as |
|------------|-----------------|
| Hosted names (92 domains plus subdomains) | `site01.example` … `site124.example` |
| The hand-patched domain | `patched-site.example` |
| A representative broken domain | `broken-site.example` |
| DirectAdmin accounts | `user01` … `user12` (`admin` kept — stock DA account) |
| nginx / PHP / phpMyAdmin versions | `<redacted>` |

Addresses and the server hostname are **not** placeholders. The EIP is the
public A record for most of these domains, `server.wbat.net` is the catch-all
certificate CN, and the detector asserts on the private addresses — masking them
would break the test and hide nothing.

Regenerating this fixture means re-running the sanitiser; do not commit a raw
`nginx -T` from a production box.

## Confirmed broken state

| Fact | Value |
|------|-------|
| Arrival / IMDS local IPv4 | `172.30.0.71` |
| EIP on eth0 | `44.214.133.234/32` |
| Stale secondary on eth0 | `172.30.0.87/24` |
| `lan_ip` in `directadmin.conf` | `172.30.0.87` (wrong) |
| Linked IP on EIP | only `172.30.0.87` (`apache=yes&dns=no`) |

**Listen asymmetry (the bug):**

- Most domain server blocks: `listen 44.214.133.234` + `listen 172.30.0.87` only.
- `patched-site.example` and the other `user09` vhosts also have `127.0.0.1`,
  `[::1]`, and `172.30.0.71` injected by the hand-patch.

Public traffic NAT’s to `.71`, so only the patched `user09` vhosts match;
everything else falls to the catch-all (`CN=server.wbat.net`).

## Hand-patch injection site

Not in `cust_nginx` / custombuild nginx templates (none present). Injects into
the **generated** user config and is re-applied from cron:

- Script: `/home/user09/bin/fix-nginx-loopback-listeners.sh`
- Also shipped under the WP plugin tree, which is the **recurrence vector**: a
  plugin redeploy can reinstate the script and its cron entry
- Target: `/usr/local/directadmin/data/users/user09/nginx.conf`
- Cron (root, every 5 min): runs the bin script with a healthchecks.io ping URL

Because it edits generated `nginx.conf`, a DA rewrite wipes it until cron
re-injects — and the inject is `user09`-only, which is how the catch-all
regression appeared for every other domain. The un-placeholdered version of
this narrative is in
[nginx-vhost-catchall-regression.md](../../nginx-vhost-catchall-regression.md).

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

This is the hash of the **original** tarball, kept for provenance. It does not
match the sanitised files in this directory and cannot be used to verify them.
