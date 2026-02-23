# CloudFront 502 (www.tellerstech.com) – Troubleshooting

When the site returns **502 Bad Gateway** from CloudFront, the failure is between **CloudFront and the origin**. The origin (server) may be fine when hit directly; CloudFront is failing to connect or get a valid response from it.

## What Terraform configures

- **Distribution**: `aws/global/cloudfront/tellerstech-website.tf`
- **Origin domain**: `origin.tellerstech.com` (variable `origin_fqdn`, default in `cloudfront/variables.tf`). *Not* the server IP.
- **Origin protocol**: HTTPS only (port 443), TLS 1.2.
- **Custom header**: `X-CloudFront-Secret` = `var.cloudfront_origin_secret` (TFC/credentials).
- **DNS**: `origin.tellerstech.com` is described as "managed in BIND" (outside this repo). `www.tellerstech.com` CNAMEs to the CloudFront domain.

CloudFront therefore connects to **https://origin.tellerstech.com** and sends the secret header. The server must respond successfully to that request.

## Checklist (when 502 appears)

1. **DNS for origin**
   - `origin.tellerstech.com` must resolve to the origin server IP (e.g. the EC2 instance).
   - From your machine: `dig +short origin.tellerstech.com` (or `nslookup origin.tellerstech.com`). If it’s wrong or missing, fix BIND (or wherever the zone is managed).

2. **HTTPS and certificate**
   - The server must listen on 443 for `origin.tellerstech.com` and present a **valid** certificate for that name (or a SAN that includes it). CloudFront does not use the IP for SNI; it uses the origin hostname.
   - From your machine:  
     `openssl s_client -connect origin.tellerstech.com:443 -servername origin.tellerstech.com </dev/null`  
     Check that the cert matches `origin.tellerstech.com` and is not expired.

3. **Nginx (or origin server)**
   - A vhost must handle `server_name origin.tellerstech.com` on 443 and serve the WordPress docroot (or proxy correctly). If the only vhost is for `www.tellerstech.com`, requests to `origin.tellerstech.com` may get the wrong site or 4xx/5xx.
   - If the server requires the `X-CloudFront-Secret` header, its value must match the Terraform variable `cloudfront_origin_secret` (e.g. in TFC variable set). A mismatch can cause the server to reject requests and CloudFront to see 403/502.
   - **DirectAdmin**: Nginx is managed by DirectAdmin; upgrades can overwrite or revert custom vhost config. If 502 appears with no Terraform changes, check that the origin vhost (and any customizations for `origin.tellerstech.com` / `www.tellerstech.com`) are still present and correct after a DirectAdmin or package update. To make custom nginx persist, use **Admin Level → Custom Httpd Config → &lt;domain&gt;** (or the domain’s `cust_nginx` / custom template), not direct edits to generated configs; then run `da build rewrite_confs`.

4. **Reachability from the internet**
   - From outside AWS:  
     `curl -sI -H "Host: origin.tellerstech.com" https://origin.tellerstech.com/`  
     (or to the server IP with `Host: origin.tellerstech.com` if you’re testing by IP). You should get a 200 (or 301/302 to login, etc.), not connection or TLS errors. If this fails, CloudFront will also fail.

5. **Terraform / TFC**
   - If you recently changed `origin_fqdn`, `cloudfront_origin_secret`, or anything that triggers a CloudFront distribution update, run `terraform plan` and confirm no unintended change. If the secret was rotated, the server must be updated to the new value.

## Quick verification

- **Origin reachable by hostname**:  
  `curl -sI https://origin.tellerstech.com/`  
  Expect 200 or a redirect, not "connection refused" or TLS error.
- **CloudFront**:  
  `curl -sI https://www.tellerstech.com/`  
  If this returns 502 but the origin curl above is OK, the problem is between CloudFront and the origin (DNS, cert, vhost, or secret).

## Summary

| Item              | Where it’s set / checked                                      |
|-------------------|---------------------------------------------------------------|
| Origin hostname   | Terraform: `origin_fqdn` → `origin.tellerstech.com`          |
| Origin HTTPS      | Terraform: `origin_protocol_policy = "https-only"`           |
| Secret header     | Terraform: `cloudfront_origin_secret` (TFC); must match server|
| DNS for origin    | BIND / external DNS → must point to origin server             |
| SSL for origin    | Server: cert for `origin.tellerstech.com` on 443              |
| Nginx vhost       | Server: `server_name origin.tellerstech.com`, correct docroot|

Fix the first item that fails in the checklist; that usually resolves the 502.

## 502 only on uncached paths (e.g. wp-login.php)

If the homepage or cached pages work but **wp-login.php** (or other uncached URLs) return 502, CloudFront is forwarding to the origin with **Host: origin.tellerstech.com**. WordPress then sees the wrong host and can redirect or error.

**Fix**: The origin request policy in `tellerstech-website.tf` must **forward the Host header** so the origin receives `Host: www.tellerstech.com`. The policy’s `headers_config` whitelist must include `"Host"`.

**Critical**: Each cache behavior has its own `origin_request_policy_id`. The **default** behavior uses the custom WordPress policy (with Host), but path-specific behaviors for `/wp-login.php`, `/wp-admin/*`, `/wp-json/*`, `/wp-cron.php`, and `/feed` were originally set to the AWS Managed **AllViewer** policy (`216adef6-...`). Those paths must use the custom `aws_cloudfront_origin_request_policy.wordpress` (same as default) so Host is forwarded; otherwise those URLs still get `Host: origin.tellerstech.com` and can 502.

**Confirm with AWS CLI** (with valid credentials):

```bash
# Get distribution ID if needed
aws cloudfront list-distributions --query "DistributionList.Items[?contains(Aliases.Items, 'www.tellerstech.com')].Id" --output text

# Show which origin request policy each behavior uses (replace DIST_ID)
aws cloudfront get-distribution-config --id DIST_ID \
  --query 'DistributionConfig.{Default:DefaultCacheBehavior.OriginRequestPolicyId,Behaviors:CacheBehaviors.Items[*].{Path:PathPattern,Policy:OriginRequestPolicyId}}' --output table
```

If `/wp-login.php` and `/wp-admin/*` show `216adef6-5c7f-47e4-b989-5492eafa07d3` (AllViewer) and the default shows a different (custom) ID, those paths were not using the Host-forwarding policy. See also `aws/docs/cloudfront-check-origin-policies.sh`.

**Server requirement**: Nginx must accept requests with `Host: www.tellerstech.com` on the same vhost (e.g. `server_name origin.tellerstech.com www.tellerstech.com;`). Otherwise requests with the forwarded Host may hit the wrong server block.
