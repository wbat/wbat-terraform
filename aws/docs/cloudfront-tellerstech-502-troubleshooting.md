# CloudFront 502 (www.tellerstech.com) – Troubleshooting

When the site returns **502 Bad Gateway** from CloudFront, the failure is between **CloudFront and the origin**. The origin (server) may be fine when hit directly; CloudFront is failing to connect or get a valid response from it.

## What Terraform configures

- **Distribution**: `aws/global/cloudfront/tellerstech-website.tf`
- **Origin domain**: `origin.tellerstech.com` (variable `origin_fqdn`, default in `cloudfront/variables.tf`). *Not* the server IP.
- **Origin protocol**: HTTPS only (port 443), TLS 1.2.
- **Custom header**: `X-CloudFront-Secret` = `var.cloudfront_origin_secret` (TFC/credentials).
- **DNS**: `origin.tellerstech.com` is described as "managed in BIND" (outside this repo). `www.tellerstech.com` CNAMEs to the CloudFront domain.

CloudFront therefore connects to **https://origin.tellerstech.com** and sends the secret header. The server must respond successfully to that request.

## Server-side companions (not in this repo)

Ops docs and scripts live in **TellersTechOrg/tellerstech-website**:

- [docs/cloudfront-wp-admin-setup.md](https://github.com/TellersTechOrg/tellerstech-website/blob/main/docs/cloudfront-wp-admin-setup.md) — nginx origin gate + wp-config Host override
- [docs/nginx-loopback-listeners.md](https://github.com/TellersTechOrg/tellerstech-website/blob/main/docs/nginx-loopback-listeners.md) — DA split-horizon listens (`172.30.0.71` / `127.0.0.1`)
- `scripts/install-cloudfront-origin-gate.sh` — install/rotate nginx gate after secret changes

**Secret must match in four places:** TFC `cloudfront_origin_secret` → CloudFront header (via TF apply) → server `wp-config.php` → DirectAdmin `tellerstech.com.cust_nginx`.

## Checklist (when 502 appears)

1. **DNS for origin**
   - `origin.tellerstech.com` must resolve to the origin server IP (e.g. the EC2 instance).
   - From your machine: `dig +short origin.tellerstech.com` (or `nslookup origin.tellerstech.com`). If it’s wrong or missing, fix BIND (or wherever the zone is managed).

2. **HTTPS and certificate (split-horizon trap)**
   - The server must present a cert for `origin.tellerstech.com` on the socket CloudFront actually hits.
   - On this host, internet/CloudFront traffic often lands on **`172.30.0.71` / `127.0.0.1`**, while DirectAdmin only generates listens on the EIP + `172.30.0.87`. Missing loopback injects → default vhost cert **`CN=server.wbat.net`** → CloudFront TLS failure → **502**.
   - On-box curls to the public EIP can still succeed (hairpin). Always check:
     `openssl s_client -connect 127.0.0.1:443 -servername origin.tellerstech.com </dev/null | openssl x509 -noout -subject`
     Expect `CN=*.origin.tellerstech.com` (or similar), **not** `server.wbat.net`.
   - Fix: `sudo /home/tellerstec/bin/fix-nginx-loopback-listeners.sh --verify` (and keep DirectAdmin `lan_ip=172.30.0.87`).

3. **Nginx origin gate vs 502**
   - Anonymous `https://origin.tellerstech.com/` without `X-CloudFront-Secret` returns **403** by design (scraper protection). That is **not** a CloudFront 502.
   - Secret mismatch (CF header ≠ nginx cust_nginx ≠ wp-config) → origin **403** → CloudFront may surface **502** or pass through 403 depending on path/caching. Align all four secret copies; reinstall gate with `install-cloudfront-origin-gate.sh` after rotation.
   - **DirectAdmin**: use parent `tellerstech.com.cust_nginx` (host-conditional). `origin.tellerstech.com.cust_nginx` is ignored (subdomain, not a DA domain). After `rewrite nginx`, immediately re-run the loopback fixer.

4. **Reachability from the internet**
   - `curl -sI https://origin.tellerstech.com/` → expect **403** (gate).
   - `curl -sI -H "X-CloudFront-Secret: $SECRET" https://origin.tellerstech.com/` → expect **200** (or WP redirect), not TLS errors.
   - If TLS shows `server.wbat.net`, fix loopback listens before debugging Terraform.

5. **Terraform / TFC**
   - If you recently changed `origin_fqdn`, `cloudfront_origin_secret`, or anything that triggers a CloudFront distribution update, run `terraform plan` and confirm no unintended change. If the secret was rotated, update **server nginx + wp-config** in the same change window (see website install script).

## Quick verification

- **Origin TLS on loopback**:
  `openssl s_client -connect 127.0.0.1:443 -servername origin.tellerstech.com </dev/null 2>/dev/null | openssl x509 -noout -subject`
  Not `server.wbat.net`.
- **Origin gate**:
  `curl -sI https://origin.tellerstech.com/` → **403** without secret.
- **CloudFront**:
  `curl -sI https://www.tellerstech.com/` → **200**. If this is 502 but loopback TLS and gated origin-with-secret are OK, re-check CF custom header value vs server.

## Summary

| Item              | Where it’s set / checked                                      |
|-------------------|---------------------------------------------------------------|
| Origin hostname   | Terraform: `origin_fqdn` → `origin.tellerstech.com`          |
| Origin HTTPS      | Terraform: `origin_protocol_policy = "https-only"`           |
| Secret header     | TFC `cloudfront_origin_secret` = CF header = wp-config = cust_nginx |
| DNS for origin    | BIND / external DNS → must point to origin server             |
| SSL for origin    | Server: cert for `origin.tellerstech.com`; loopback listens required |
| Nginx vhost       | DA + `fix-nginx-loopback-listeners.sh`; parent cust_nginx gate |

Fix the first item that fails in the checklist; that usually resolves the 502.

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
