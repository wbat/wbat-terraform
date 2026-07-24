# CloudFront 502 (www.tellerstech.com) – Troubleshooting

When the site returns **502 Bad Gateway** from CloudFront, the failure is between **CloudFront and the origin**. The origin (server) may be fine when hit directly; CloudFront is failing to connect or get a valid response from it.

## What Terraform configures

- **Distribution**: `aws/global/cloudfront/tellerstech-website.tf`
- **Origin domain**: `origin.tellerstech.com` (variable `origin_fqdn`, default in `cloudfront/variables.tf`). *Not* the server IP.
- **Origin protocol**: HTTPS only (port 443), TLS 1.2.
- **Custom header**: `X-CloudFront-Secret` = `var.cloudfront_origin_secret` (TFC/credentials).
- **Custom error pages**: private S3 bucket + OAC (`error-pages.tf`); `custom_error_response` maps **5xx only** (500/502/503/504 → `/errors/503.html`), keeping the **real status code**. **404/403 are not remapped** so WordPress keeps the full-chrome TT 404.
- **DNS**: `origin.tellerstech.com` is described as "managed in BIND" (outside this repo). `www.tellerstech.com` CNAMEs to the CloudFront domain.

CloudFront therefore connects to **https://origin.tellerstech.com** and sends the secret header. The server must respond successfully to that request.

## Cache key vs query-string floods

WordPress and podcast cache policies put only **functional** query strings in the
cache key (AWS soft quota: **max 10** — currently `s`, `p`, `page_id`, `page`,
`paged`, `preview`, `preview_id`, `preview_nonce`, `order`, `orderby`). Marketing /
random params (`utm_*`, `gclid`, `fbclid`, unique junk) share the same cached
object as the clean URL, so a scrape of `/?x=<random>` cannot force a miss per
request. Origin request policy still forwards **all** query strings on a cache miss.

## wp-admin redirects to origin (403)

Exact path `/wp-admin` (no trailing slash) is **not** matched by `/wp-admin/*`, so it used the default cache behavior. Nginx’s trailing-slash 301 used `Host: origin.tellerstech.com`, CloudFront cached `Location: https://origin.tellerstech.com/wp-admin/`, and browsers then hit the gated origin → **403**.

**Mitigations (applied):** `aws/global/cloudfront/functions.tf` redirects `/wp-admin` → `https://www.tellerstech.com/wp-admin/` and rewrites any `Location: …origin.tellerstech.com…` → www; an exact `/wp-admin` CachingDisabled behavior avoids re-caching a bad 301. Prefer `https://www.tellerstech.com/wp-admin/` (trailing slash) as the bookmark.
## Branded error pages (www)

When CloudFront cannot reach the origin or the origin returns **5xx** (500/502/503/504), viewers of **www.tellerstech.com** get static HTML from S3 (`/errors/503.html`). Status codes are unchanged (no fake 200).

**404** (and origin **403**) are left alone so WordPress can serve the full-chrome TT 404 (`tt_render_404_page`). Static `403.html` / `404.html` remain in the bucket under `/errors/*` for direct checks, but are not wired as `custom_error_response`.

- Direct check: `curl -sI https://www.tellerstech.com/errors/503.html` → **200** from the S3 origin behavior.
- Missing path: `curl -sI https://www.tellerstech.com/this-path-does-not-exist-tt/` → **404** from WordPress (site nav/footer), not S3.
- Direct `origin.tellerstech.com` bypasses CloudFront and does **not** get these pages.

## Server-side companions (not in this repo)

Ops docs and scripts live in **TellersTechOrg/tellerstech-website**:

- [docs/cloudfront-wp-admin-setup.md](https://github.com/TellersTechOrg/tellerstech-website/blob/main/docs/cloudfront-wp-admin-setup.md) — nginx origin gate + wp-config Host override + pointers to this runbook (5xx pages, cache keys, `/wp-admin`)
- [docs/nginx-loopback-listeners.md](https://github.com/TellersTechOrg/tellerstech-website/blob/main/docs/nginx-loopback-listeners.md) — DA split-horizon listens (`172.30.0.71` / `127.0.0.1`)
- `scripts/install-cloudfront-origin-gate.sh` — install/rotate nginx gate after secret changes

**Secret must match in four places:** TFC `cloudfront_origin_secret` → CloudFront header (via TF apply) → server `wp-config.php` → DirectAdmin `tellerstech.com.cust_nginx`.

## Checklist (when 502 appears)

1. **DNS for origin**
   - `origin.tellerstech.com` must resolve to the origin server IP (e.g. the EC2 instance).
   - From your machine: `dig +short origin.tellerstech.com` (or `nslookup origin.tellerstech.com`). If it’s wrong or missing, fix BIND (or wherever the zone is managed).

2. **HTTPS and certificate (split-horizon trap)**
   - The server must present a cert whose name/SAN covers **`origin.tellerstech.com`** on the socket CloudFront actually hits (exact `origin.tellerstech.com` or a parent wildcard such as `*.tellerstech.com`). A cert for `*.origin.tellerstech.com` alone does **not** cover the origin host.
   - On this host, internet/CloudFront traffic often lands on **`172.30.0.71` / `127.0.0.1`**, while DirectAdmin only generates listens on the EIP + `172.30.0.87`. Missing loopback injects → default vhost cert **`CN=server.wbat.net`** → CloudFront TLS failure → **502**.
   - On-box curls to the public EIP can still succeed (hairpin). Always check Subject **and** SANs:
     `openssl s_client -connect 127.0.0.1:443 -servername origin.tellerstech.com </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName`
     Expect a name that covers `origin.tellerstech.com`, **not** `server.wbat.net` (and not only `*.origin.tellerstech.com`).
   - Fix: `sudo /home/tellerstec/bin/fix-nginx-loopback-listeners.sh --verify` (and keep DirectAdmin `lan_ip=172.30.0.87`).

3. **Nginx origin gate (403, not 502)**
   - Anonymous `https://origin.tellerstech.com/` without `X-CloudFront-Secret` returns **403** by design (scraper protection). That is **not** a CloudFront 502.
   - Secret mismatch (CF header ≠ nginx cust_nginx ≠ wp-config) also yields origin **403**. CloudFront does **not** remap 403 to a custom page (or to 502). Debug secret rotation when you observe **403**, not when debugging **502**.
   - Reserve **502** for connection/TLS/DNS/origin-unreachable failures (checklist items 1–2 and 4). A viewer-facing **502** may show the branded “Temporarily unavailable” S3 page while the status remains 502.
   - When debugging **403** after a rotation: align all four secret copies; reinstall gate with `install-cloudfront-origin-gate.sh`.
   - **DirectAdmin**: use parent `tellerstech.com.cust_nginx` (host-conditional). `origin.tellerstech.com.cust_nginx` is ignored (subdomain, not a DA domain). After `rewrite nginx`, immediately re-run the loopback fixer.

4. **Reachability from the internet**
   - `curl -sI https://origin.tellerstech.com/` → expect **403** (gate).
   - `curl -sI -H "X-CloudFront-Secret: $SECRET" https://origin.tellerstech.com/` → expect **200** (or WP redirect), not TLS errors.
   - If TLS shows `server.wbat.net`, fix loopback listens before debugging Terraform.

5. **Terraform / TFC**
   - If you recently changed `origin_fqdn`, `cloudfront_origin_secret`, or anything that triggers a CloudFront distribution update, run `terraform plan` and confirm no unintended change. If the secret was rotated, update **server nginx + wp-config** in the same change window (see website install script).

## Quick verification

- **Origin TLS on loopback**:
  `openssl s_client -connect 127.0.0.1:443 -servername origin.tellerstech.com </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName`
  Must cover `origin.tellerstech.com` (not only `*.origin.tellerstech.com`); not `server.wbat.net`.
- **Origin gate (403 path)**:
  `curl -sI https://origin.tellerstech.com/` → **403** without secret.
  `curl -sI -H "X-CloudFront-Secret: $SECRET" https://origin.tellerstech.com/` → **200** (or WP redirect).
- **CloudFront**:
  `curl -sI https://www.tellerstech.com/` → **200**. If this is **502**, prioritize DNS/TLS/loopback (items 1–2, 4). If this is **403**, check secret alignment (item 3).

## Summary

| Item              | Where it’s set / checked                                      |
|-------------------|---------------------------------------------------------------|
| Origin hostname   | Terraform: `origin_fqdn` → `origin.tellerstech.com`          |
| Origin HTTPS      | Terraform: `origin_protocol_policy = "https-only"`           |
| Secret header     | TFC `cloudfront_origin_secret` = CF header = wp-config = cust_nginx → mismatch is **403**, not 502 |
| DNS for origin    | BIND / external DNS → must point to origin server             |
| SSL for origin    | Server: name/SAN covering `origin.tellerstech.com`; loopback listens required (**502** if wrong) |
| Nginx vhost       | DA + `fix-nginx-loopback-listeners.sh`; parent cust_nginx gate |
| Error HTML (www)  | Terraform: S3 + OAC; `custom_error_response` for **5xx only** → `/errors/503.html` |

For **502**, fix the first failing DNS/TLS/reachability check. For **403**, align the secret gate.

## 502 only on uncached paths (e.g. wp-login.php)

If the homepage or cached pages work but **wp-login.php** (or other uncached URLs) return 502, CloudFront is forwarding to the origin with **Host: origin.tellerstech.com**. WordPress then sees the wrong host and can redirect or error.

**Fix**: Keep the origin request policy and `wp-config.php` CloudFront block aligned (secret-gated Host override to `www.tellerstech.com`). See the website `cloudfront-wp-admin-setup.md`. Path-specific cache behaviors must use the same WordPress origin request policy as the default behavior (not Managed AllViewer) where applicable in `tellerstech-website.tf`.

**Confirm with AWS CLI** (with valid credentials):

```bash
# Get distribution ID if needed
aws cloudfront list-distributions --query "DistributionList.Items[?contains(Aliases.Items, 'www.tellerstech.com')].Id" --output text

# Show which origin request policy each behavior uses (replace DIST_ID)
aws cloudfront get-distribution-config --id DIST_ID \
  --query 'DistributionConfig.{Default:DefaultCacheBehavior.OriginRequestPolicyId,Behaviors:CacheBehaviors.Items[*].{Path:PathPattern,Policy:OriginRequestPolicyId}}' --output table
```
