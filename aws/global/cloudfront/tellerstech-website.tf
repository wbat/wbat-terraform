# CloudFront Distribution for www.tellerstech.com
# WordPress-optimized caching with full page cache for anonymous visitors

# Cache policy for WordPress - forwards session cookies to bypass cache for logged-in users.
# Query strings in the *cache key* are whitelisted only: marketing params (utm_*, gclid,
# fbclid, …) must not fragment the cache or a scrape of unique ?x= values will miss-cache
# every request and burn PHP-FPM. Origin request policy still forwards all query strings
# on a miss so WordPress can see them when needed.
resource "aws_cloudfront_cache_policy" "wordpress" {
  name        = "WordPress-CachePolicy"
  comment     = "WordPress pages: session cookies + functional query strings only in cache key"
  min_ttl     = 0
  default_ttl = 7200  # 2 hours
  max_ttl     = 86400 # 1 day

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config {
      cookie_behavior = "whitelist"
      cookies {
        items = [
          "wordpress_*",
          "wp-*",
          "comment_*",
        ]
      }
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "whitelist"
      query_strings {
        items = [
          "s",
          "p",
          "page_id",
          "page",
          "paged",
          "preview",
          "preview_id",
          "preview_nonce",
          "order",
          "orderby",
          "cat",
          "tag",
          "author",
          "attachment_id",
          "replytocom",
        ]
      }
    }
  }
}

# Cache policy for the high-traffic Ship It Weekly landing pages (hub, host,
# media kit) - same as WordPress policy but capped at 12 hours so these pages
# refresh at least twice a day. Individual episodes are NOT included here and
# keep the default 1 day ceiling.
resource "aws_cloudfront_cache_policy" "podcast" {
  name        = "Podcast-CachePolicy"
  comment     = "SIW landing pages: 12h max TTL; functional query strings only in cache key"
  min_ttl     = 0
  default_ttl = 7200  # 2 hours
  max_ttl     = 43200 # 12 hours

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config {
      cookie_behavior = "whitelist"
      cookies {
        items = [
          "wordpress_*",
          "wp-*",
          "comment_*",
        ]
      }
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "whitelist"
      query_strings {
        items = [
          "s",
          "p",
          "page_id",
          "page",
          "paged",
          "preview",
          "preview_id",
          "preview_nonce",
          "order",
          "orderby",
          "cat",
          "tag",
          "author",
          "attachment_id",
          "replytocom",
        ]
      }
    }
  }
}

# Cache policy for static assets - no cookies, long TTL
resource "aws_cloudfront_cache_policy" "static_assets" {
  name        = "StaticAssets-CachePolicy"
  comment     = "Cache policy for static assets - long TTL, no cookies"
  min_ttl     = 86400    # 1 day minimum
  default_ttl = 604800   # 1 week
  max_ttl     = 31536000 # 1 year

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

# Origin request policy - forwards Host header to origin
resource "aws_cloudfront_origin_request_policy" "wordpress" {
  name    = "WordPress-OriginRequestPolicy"
  comment = "Forward Host header and WordPress cookies to origin"

  cookies_config {
    cookie_behavior = "whitelist"
    cookies {
      items = [
        "wordpress_*",
        "wp-*",
        "comment_*",
      ]
    }
  }

  headers_config {
    header_behavior = "whitelist"
    headers {
      items = [
        "X-WP-Nonce",
        "CloudFront-Forwarded-Proto",
        "CloudFront-Is-Desktop-Viewer",
        "CloudFront-Is-Mobile-Viewer",
        "CloudFront-Is-Tablet-Viewer",
        # Real viewer "<ip>:<port>", set by CloudFront (un-spoofable). Lets the
        # origin log the actual subscriber IP instead of the CDN edge IP. Read by
        # ocb_client_ip() in tellerstech-ocb-subscribers.php. Forwarded only (not
        # in the cache key), so it does not fragment the cache.
        "CloudFront-Viewer-Address",
        # Real viewer User-Agent. Without this, CloudFront forwards the literal
        # "Amazon CloudFront" to the origin, so the newsletter click/open tracking
        # (/{list}-click, /{list}-open) logged every device/OS/browser as
        # Desktop/Other/Other in the analytics dashboard. Parsed by tt_ua_parse()
        # in tellerstech-ocb-analytics.php. Forwarded via the ORIGIN REQUEST policy
        # only (not the cache policy), so it does NOT become part of the cache key
        # and does not fragment the page cache.
        "User-Agent",
        # CloudFront-derived geolocation, generated by CloudFront at the edge for
        # BOTH IPv4 and IPv6 viewers. Lets OCB newsletter analytics geolocate
        # subscribers without a MaxMind lookup (which was silently failing on the
        # IPv6 addresses seen in signups). Consumed by the OCB analytics code in
        # WordPress. Forwarded via the ORIGIN REQUEST policy only (not the cache
        # policy), so these do NOT become part of the cache key and do not
        # fragment the page cache.
        #
        # NOTE: CloudFront caps an origin request policy at 10 headers (soft quota
        # L-C646B44B). The 7 headers above + these 3 hit that limit exactly, so we
        # forward only country/region/city (the ISO country code maps to a name and
        # flag downstream). To add lat/long, postal code, or time zone, request a
        # quota increase first, otherwise CloudFront returns
        # TooManyHeadersInOriginRequestPolicy.
        "CloudFront-Viewer-Country",
        "CloudFront-Viewer-Country-Region",
        "CloudFront-Viewer-City",
      ]
    }
  }

  query_strings_config {
    query_string_behavior = "all"
  }
}

# Response headers policy for static assets - override origin's no-cache headers
resource "aws_cloudfront_response_headers_policy" "static_assets" {
  name    = "StaticAssets-ResponseHeadersPolicy"
  comment = "Add proper cache headers for static assets"

  custom_headers_config {
    items {
      header   = "Cache-Control"
      value    = "public, max-age=31536000"
      override = true
    }
    items {
      header   = "Expires"
      value    = "Thu, 31 Dec 2037 23:59:59 GMT"
      override = true
    }
  }
}

# Main CloudFront distribution
resource "aws_cloudfront_distribution" "tellerstech_website" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "www.tellerstech.com - WordPress with full page caching"
  default_root_object = ""
  price_class         = "PriceClass_100" # US, Canada, Europe
  aliases             = ["www.tellerstech.com"]
  web_acl_id          = var.enable_waf ? aws_wafv2_web_acl.tellerstech[0].arn : null

  origin {
    domain_name = var.origin_fqdn
    origin_id   = "wordpress-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-CloudFront-Secret"
      value = var.cloudfront_origin_secret
    }
  }

  # Static branded error pages (private S3 + OAC). Used by custom_error_response
  # and by direct GETs to /errors/*.html when debugging.
  origin {
    domain_name              = aws_s3_bucket.cf_errors.bucket_regional_domain_name
    origin_id                = "error-pages-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.cf_errors.id
  }

  # Default behavior - WordPress pages with session cookie handling
  default_cache_behavior {
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "wordpress-origin"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = aws_cloudfront_cache_policy.wordpress.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.wordpress.id

    # /wp-admin (no trailing slash) falls through here — not matched by /wp-admin/*.
    # Edge functions stop nginx Host-based redirects to origin.tellerstech.com.
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.wp_admin_trailing_slash.arn
    }
    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.rewrite_origin_location.arn
    }
  }

  # Preferential: serve error HTML from S3 (must be first ordered behavior).
  ordered_cache_behavior {
    path_pattern           = "/errors/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "error-pages-s3"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS Managed CachingOptimized
  }

  # Ship It Weekly hub page - capped at 12 hours (Podcast-CachePolicy) so the
  # latest-episodes list does not go stale. EXACT match: the pattern has no "*",
  # so it matches only "/ship-it-weekly-podcast/" and NOT the episode pages
  # underneath it (e.g. /ship-it-weekly-podcast/<slug>/), which keep the default
  # 1 day ceiling.
  ordered_cache_behavior {
    path_pattern             = "/ship-it-weekly-podcast/"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "wordpress-origin"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = aws_cloudfront_cache_policy.podcast.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.wordpress.id
  }

  # Ship It Weekly host page - capped at 12 hours (exact match).
  ordered_cache_behavior {
    path_pattern             = "/ship-it-weekly-podcast/host/"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "wordpress-origin"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = aws_cloudfront_cache_policy.podcast.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.wordpress.id
  }

  # Ship It Weekly media kit - capped at 12 hours (exact match).
  ordered_cache_behavior {
    path_pattern             = "/ship-it-weekly-podcast/media-kit/"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "wordpress-origin"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = aws_cloudfront_cache_policy.podcast.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.wordpress.id
  }

  # Exact /wp-admin (no trailing slash). /wp-admin/* does NOT match this path, so
  # without this block it used the default cache policy and CloudFront cached
  # nginx's 301 to https://origin.tellerstech.com/wp-admin/ → viewer 403.
  ordered_cache_behavior {
    path_pattern             = "/wp-admin"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "wordpress-origin"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS Managed CachingDisabled
    origin_request_policy_id = aws_cloudfront_origin_request_policy.wordpress.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.wp_admin_trailing_slash.arn
    }
    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.rewrite_origin_location.arn
    }
  }

  # wp-admin - no caching, use WordPress policy (origin gets Host: origin.tellerstech.com;
  # wp-config.php overrides $_SERVER['HTTP_HOST'] to www.tellerstech.com via X-CloudFront-Secret)
  ordered_cache_behavior {
    path_pattern             = "/wp-admin/*"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "wordpress-origin"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS Managed CachingDisabled
    origin_request_policy_id = aws_cloudfront_origin_request_policy.wordpress.id

    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.rewrite_origin_location.arn
    }
  }

  # wp-login.php - no caching
  ordered_cache_behavior {
    path_pattern             = "/wp-login.php"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "wordpress-origin"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS Managed CachingDisabled
    origin_request_policy_id = aws_cloudfront_origin_request_policy.wordpress.id

    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.rewrite_origin_location.arn
    }
  }

  # wp-json API - no caching
  ordered_cache_behavior {
    path_pattern             = "/wp-json/*"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "wordpress-origin"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS Managed CachingDisabled
    origin_request_policy_id = aws_cloudfront_origin_request_policy.wordpress.id
  }

  # wp-cron.php - no caching
  ordered_cache_behavior {
    path_pattern             = "/wp-cron.php"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "wordpress-origin"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS Managed CachingDisabled
    origin_request_policy_id = aws_cloudfront_origin_request_policy.wordpress.id
  }

  # RSS/Atom feeds - no caching (must always be fresh for podcast apps)
  ordered_cache_behavior {
    path_pattern             = "/feed/*"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "wordpress-origin"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS Managed CachingDisabled
    origin_request_policy_id = aws_cloudfront_origin_request_policy.wordpress.id
  }

  # Root feed endpoint - no caching
  ordered_cache_behavior {
    path_pattern             = "/feed"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "wordpress-origin"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS Managed CachingDisabled
    origin_request_policy_id = aws_cloudfront_origin_request_policy.wordpress.id
  }

  # Sitemaps - short cache (2 hour default like WordPress pages)
  ordered_cache_behavior {
    path_pattern             = "*.xml"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "wordpress-origin"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = aws_cloudfront_cache_policy.wordpress.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.wordpress.id
  }

  # Static assets - long cache TTL
  ordered_cache_behavior {
    path_pattern               = "/wp-content/*"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "wordpress-origin"
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.static_assets.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.static_assets.id
  }

  # wp-includes static assets - long cache TTL
  ordered_cache_behavior {
    path_pattern               = "/wp-includes/*"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "wordpress-origin"
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.static_assets.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.static_assets.id
  }

  # Root-level static files (favicon, etc.)
  ordered_cache_behavior {
    path_pattern               = "*.svg"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "wordpress-origin"
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.static_assets.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.static_assets.id
  }

  ordered_cache_behavior {
    path_pattern               = "*.ico"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "wordpress-origin"
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.static_assets.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.static_assets.id
  }

  # Branded static pages from the error-pages-s3 origin for outages only.
  # Do NOT remap 404/403 — WordPress serves the full-chrome TT 404 (and origin
  # gate 403s stay as nginx). response_code matches error_code (no fake 200).
  custom_error_response {
    error_code            = 500
    response_code         = 500
    response_page_path    = "/errors/503.html"
    error_caching_min_ttl = 30
  }

  custom_error_response {
    error_code            = 502
    response_code         = 502
    response_page_path    = "/errors/503.html"
    error_caching_min_ttl = 30
  }

  custom_error_response {
    error_code            = 503
    response_code         = 503
    response_page_path    = "/errors/503.html"
    error_caching_min_ttl = 30
  }

  custom_error_response {
    error_code            = 504
    response_code         = 504
    response_page_path    = "/errors/503.html"
    error_caching_min_ttl = 30
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech.com Website CDN"
      "scm:file" = "aws/global/cloudfront/tellerstech-website.tf"
    },
  )
}
