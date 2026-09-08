# Known-bad fixture: nginx catch-all vhost regression

Captured **2026-07-26T21:55:13Z** from primary `i-0118b8ede80b52ef7`
(`server.wbat.net`) via SSM **before** any Linked-IP / reconciler changes.

Use this as the offline known-bad input for the nginx `-T` invariant parser
(`prove-detector` / static invariant). Do not “fix” these files in place —
regenerate a new fixture after the change window if a post-fix baseline is
needed.

> **These files are sanitised.** This repository is public and the raw capture
> named every hosted domain, every DirectAdmin account, and the exact package
> versions. See [Sanitisation](#sanitisation) before trusting a name in here or
> regenerating the fixture.

## Confirmed broken state

| Fact | Value |
|------|-------|
| Arrival / IMDS local IPv4 | `172.30.0.71` |
| EIP on eth0 | `44.214.133.234/32` |
| Stale secondary on eth0 | `172.30.0.87/24` |
| `lan_ip` in `directadmin.conf` | `172.30.0.87` (wrong) |
| Linked IP on EIP | only `172.30.0.87` (`apache=yes&dns=no`) |
| Web stack | nginx + PHP-FPM via CustomBuild (versions redacted) |

**Listen asymmetry (the bug):**

- Most domain server blocks: `listen 44.214.133.234` + `listen 172.30.0.87` only.
- `patched-site.example` / related user09 vhosts also have `127.0.0.1`, `[::1]`,
  and `172.30.0.71` injected by the hand-patch.

Public traffic NAT’s to `.71`, so only the patched user09 vhosts match;
everything else falls to the catch-all (`CN=server.wbat.net`).

## Hand-patch injection site

Not in `cust_nginx` / custombuild nginx templates (none present). Injects into
the **generated** user config and is re-applied from cron:

- Script: `/home/user09/bin/fix-nginx-loopback-listeners.sh`
- Also shipped under the WP plugin tree:
  `.../plugins/tellerstech-landing/scripts/fix-nginx-loopback-listeners.sh`
- Target: `/usr/local/directadmin/data/users/user09/nginx.conf`
- Cron (root, every 5 min): runs the bin script with a healthchecks.io ping URL

Because it edits generated `nginx.conf`, a DA rewrite wipes it until cron
re-injects — and the inject is user09-only, which is how the catch-all
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

## Sanitisation

Run by `scripts/directadmin/sanitize_nginx_capture.py`, which is versioned here
so the transformation is reproducible and so nobody has to invent one under
pressure and commit a raw dump by accident.

| Real value | Becomes | Why |
|------------|---------|-----|
| Customer domains (from `domainowners.txt`) | `siteNN.example` | Hosted third parties should not be enumerable from this repo |
| DirectAdmin account names | `userNN` | The disclosure that actually matters: an account name is half a credential pair for DirectAdmin, SSH, FTP and mail, and is not otherwise discoverable |
| The two sites the bug is demonstrated on | `patched-site.example`, `broken-site.example` | Role names, for readability rather than secrecy — both are the operator's own sites |
| PHP branch in FastCGI socket paths | `phpXY` | `/usr/local/php82/sockets/...` discloses the default PHP branch even with the versions file redacted |
| `Label: 1.2.3` in the CustomBuild dump | `Label: <redacted>` | `server_tokens` is off, so this capture would be the only public source of exact versions |

Deliberately **not** placeholdered:

- **IP addresses.** The EIP is the public A record for most of these domains and
  the private addresses are what the detector asserts on. Masking them would
  break the proof while hiding nothing.
- **`server.wbat.net` / `wbat.net`.** Public via DNS and certificate
  transparency, it is the catch-all certificate CN that makes the symptom
  legible, and the detector's allowlist matches on it.
- **Instance ID, capture timestamp, block structure, listen counts.**

Subdomain labels survive the domain swap (`www.x.com` → `www.siteNN.example`),
and one original hostname maps to exactly one placeholder in every context it
appears — `server_name`, docroot, access/error log paths, certificate paths and
the per-account socket. That consistency is the point: a fixture that gave one
hostname three different placeholders would fabricate relationships that were
never in the capture.

### Regenerating

```bash
# 1. capture to a scratch dir on the box, pull it down, and keep the raw copy
#    OUT of the repo -- put it somewhere like /tmp/raw-capture
# 2. copy it in, then sanitise in place:
scripts/directadmin/sanitize_nginx_capture.py aws/docs/fixtures/<new-fixture>

# 3. prove nothing identifying survived (scans for every original account and
#    domain as a literal token anywhere in the tree, not just in path context):
scripts/directadmin/sanitize_nginx_capture.py --verify \
  aws/docs/fixtures/<new-fixture> /tmp/raw-capture

# 4. prove the fixture is still the same test input -- line, listen and
#    server_name counts must be identical to the raw capture, and the detector
#    must report the same number of failures against both:
bash scripts/directadmin/nginx_vhost_listen_invariant.sh --arrival <arrival-ip> \
  --file <dir>/nginx-T.full.txt --allowlist 'server.wbat.net wbat.net' \
  | grep -c '^FAIL '

# 5. and the offline proof must still pass:
bash scripts/directadmin/prove_vhost_listen_detector.sh
```

Step 4 is not ceremony. It caught a real defect while this fixture was being
built: the account pass rewrote the `wbat` inside `www.wbat.net`, which silently
moved two server blocks out of the allowlist and changed the detector's verdict
from 157 failures to 159.

For this fixture, both the raw capture and the sanitised tree yield **157**
detector failures at arrival `172.30.0.71`, with identical line counts (9519),
`listen` counts (442) and `server_name` counts (187).

## Provenance

SHA-256 of the raw capture tarball, as it sat in `/tmp` on the instance at
capture time: `9b25d480e1fa6679fa4082517ff2a48eed617855daaf8487b484f85081b836c7`

The published files are the sanitised derivative, so they do not hash to that
value. The raw tarball is not in this repository and should not be added to it.
