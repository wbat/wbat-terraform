# CloudFront Distribution for www.tellerstech.com
# WordPress-optimized caching with full page cache for anonymous visitors

# Cache policy for WordPress - forwards session cookies to bypass cache for logged-in users
resource "aws_cloudfront_cache_policy" "wordpress" {
  name        = "WordPress-CachePolicy"
  comment     = "Cache policy for WordPress - bypasses cache when session cookies present"
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
      query_string_behavior = "all"
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

  # Default behavior - WordPress pages with session cookie handling
  default_cache_behavior {
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "wordpress-origin"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = aws_cloudfront_cache_policy.wordpress.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.wordpress.id
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
