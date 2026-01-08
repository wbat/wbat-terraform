######################################################
# Legacy W3TC CDN Distribution
#
# This distribution was originally created by W3 Total Cache
# and is no longer in use. It has been imported to Terraform
# for IaC management. Safe to delete when no longer needed.
#
# To remove: Set enabled = false, apply, wait for deploy,
# then remove the resource and apply again.
######################################################

import {
  to = aws_cloudfront_distribution.cdn_legacy
  id = "E1BJFU3JD7PL7F"
}

resource "aws_cloudfront_distribution" "cdn_legacy" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "Legacy W3TC CDN - No longer in use (was: Created by W3-Total-Cache)"
  price_class     = "PriceClass_All"
  http_version    = "http2"

  aliases = ["cdn.aws.tellerstech.com"]

  origin {
    domain_name = "www.tellerstech.com"
    origin_id   = "www.tellerstech.com"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "match-viewer"
      origin_ssl_protocols     = ["TLSv1", "TLSv1.1", "TLSv1.2"]
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "www.tellerstech.com"
    compress         = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = "arn:aws:acm:us-east-1:708113892725:certificate/f0061e68-95cc-47cd-a7be-34679217bd0c"
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = var.core_tags
}
