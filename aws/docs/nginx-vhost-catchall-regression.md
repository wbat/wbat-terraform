# All sites except tellerstech.com serve the default page (no valid SSL)

**Symptom:** after the CloudFront/origin work for `tellerstech.com`, every *other* domain on
the primary EC2 instance (`iots.com`, `lmgt.com`, `wbat.net`, …) serves
`webserver is functioning normally` and presents the default certificate
**`CN=server.wbat.net`**, so browsers show an SSL name mismatch.

This is the **same split-horizon listen trap** described in
[cloudfront-tellerstech-502-troubleshooting.md](cloudfront-tellerstech-502-troubleshooting.md)
(checklist item 2), only inverted: the loopback/private-IP listens were injected for
`tellerstech.com` **per domain**, so `tellerstech.com` is now the *only* vhost bound to the
address that public traffic actually arrives on. Everything else falls through to the
DirectAdmin catch-all.

## Evidence (observed 2026-07-26, from outside the VPC)

All hostnames resolve to the primary EIP `44.214.133.234`.

| Hostname                  | Cert presented              | Body                                |
|---------------------------|-----------------------------|-------------------------------------|
| `origin.tellerstech.com`  | `*.origin.tellerstech.com`  | WordPress (gated)                   |
| `tellerstech.com`         | `*.tellerstech.com`         | 301 → `www`                         |
| `iots.com`, `www.iots.com`| `server.wbat.net`           | `webserver is functioning normally` |
| `lmgt.com`, `www.lmgt.com`| `server.wbat.net`           | `webserver is functioning normally` |
| `mail.tellerstech.com`    | `server.wbat.net`           | `webserver is functioning normally` |
| *(nonexistent SNI)*       | `server.wbat.net`           | `webserver is functioning normally` |

`wbat.net` also lands on the catch-all, but that may be legitimate if it has no site vhost of
its own — `server.wbat.net` is the box's own hostname.

Three observations pin the cause:

1. **A bogus SNI hostname and a bare-IP request return byte-identical responses**
   (same `Content-Length: 47`, same `ETag`) to `iots.com` and `lmgt.com`. Those domains are
   not being matched to their own server blocks at all — they are hitting the catch-all.
2. **It is broken on port 80 too**, not just 443. A certificate or `ssl_certificate`
   misconfiguration cannot explain a plain-HTTP failure. This is **server-block selection**.
3. **Only the two hostnames that received the loopback fix work.** `tellerstech.com` and
   `origin.tellerstech.com` resolve correctly; every other vhost on the box, including
   unrelated domains, does not.

The catch-all's index file is dated `Last-Modified: Thu, 23 Jul 2026 20:59:54 GMT` — inside
the same change window as the origin-gate / loopback work, i.e. nginx vhosts were
regenerated (`da build rewrite_confs` / `rewrite nginx`) during that change.

## Why this happens

Nginx does **not** pick a server block by `server_name` first. It picks the **listen address
group** first, by most-specific match on the local address the connection arrived on, and
only then matches `server_name`/SNI *within that group*. If no `server_name` in the group
matches, the group's `default_server` answers.

On this host, internet traffic arrives NAT'd to the instance's **primary private IP**
(`172.30.0.71`) — never to the EIP literal, which AWS translates upstream and which is not a
local address. DirectAdmin, however, generates per-domain listens for the **EIP + the stale
`172.30.0.87`**. Those sockets receive no public traffic.

So after the vhost regeneration:

- `tellerstech.com` / `origin.tellerstech.com` — loopback fixer re-injected
  `172.30.0.71` / `127.0.0.1` listens → **matched → correct cert → works**.
- Every other domain — only EIP + `172.30.0.87` listens → **never matched** → falls to the
  wildcard catch-all → `server.wbat.net` cert + default page.

Nothing in Terraform caused this, and nothing in Terraform can fix it: the CloudFront/ACM/SES
resources in this repo are unrelated to nginx vhost binding. The regression is entirely in
the host's nginx configuration.

## Second-order damage: certificate renewals

The affected domains' certificates on disk are probably still valid — they are simply never
*selected*. Fixing vhost matching should restore SSL immediately.

But Let's Encrypt **HTTP-01 validation is already failing**, because the challenge path also
lands on the catch-all:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  http://iots.com/.well-known/acme-challenge/probe-test    # → 404 (should be 404 from the
                                                           #   domain's docroot, not the catch-all)
```

Renewals for these domains cannot complete while this is broken, so leaving it unfixed turns
a name-mismatch warning into hard expiry. Re-check renewal state after the fix.

## On-box diagnosis

```bash
# Which address does nginx actually have bound, and which servers are in each group?
sudo nginx -T | grep -nE '^\s*(listen|server_name)' | less

# The address public traffic lands on (primary private IP of this instance):
ip -4 addr show scope global
curl -s http://169.254.169.254/latest/meta-data/local-ipv4; echo

# Confirm a broken domain has no listen on that address:
sudo nginx -T | grep -A15 'server_name .*iots\.com' | grep listen

# Compare with the domain that works:
sudo nginx -T | grep -A15 'server_name .*tellerstech\.com' | grep listen
```

Expect the working domain to show `172.30.0.71` / `127.0.0.1` listens that the broken ones
lack.

## Fix

**Do not** simply re-run the per-domain fixer for `iots.com` and `lmgt.com`. That repeats the
mistake that caused this and has to be redone after every DirectAdmin `rewrite_confs`.

Fix the root cause — make DirectAdmin generate vhosts on the address that actually receives
traffic:

1. Point DirectAdmin's server IP at the instance's real primary private IP (`172.30.0.71`),
   or configure the vhost template to use **wildcard listens** (`listen 80;` /
   `listen 443 ssl;`) so vhost selection falls back to SNI/Host for every domain regardless
   of which local address the packet arrived on.
2. Rebuild: `da build rewrite_confs`, then `nginx -t && systemctl reload nginx`.
3. Re-verify **every** domain, not just `tellerstech.com` (see the script below).
4. Once vhosts bind the correct address server-wide, `fix-nginx-loopback-listeners.sh`
   becomes redundant for `tellerstech.com` — keep it only if the loopback (`127.0.0.1`)
   listen is still needed for on-box checks.

Interim mitigation, if the DirectAdmin IP change cannot be made immediately: extend
`fix-nginx-loopback-listeners.sh` (in `TellersTechOrg/tellerstech-website`) to iterate **all**
DirectAdmin domains rather than `tellerstech.com` only, and run it from a
`post_rewrite_confs` hook so it survives regeneration.

## Prevention

- Treat any per-domain `listen` injection on this host as a **server-wide** change. Adding an
  explicit address to one vhost silently removes that address from every vhost that lacks it.
- Make the catch-all fail loudly instead of returning `200`. A default vhost that answers
  `webserver is functioning normally` with a `200` looks healthy to uptime checks; returning
  `421`/`444` there would have surfaced this within minutes.
- After any `rewrite nginx` / `da build rewrite_confs`, run the multi-domain verification
  below before closing the change window.

## Verification

Use [`check-vhost-listeners.sh`](check-vhost-listeners.sh) to confirm every hosted domain is
matched to its own vhost, from outside the VPC:

```bash
./check-vhost-listeners.sh tellerstech.com iots.com lmgt.com wbat.net
```

Any domain reported as `CATCH-ALL` is unreachable on its own vhost and has no valid SSL.
