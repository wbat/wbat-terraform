# AWS WAF for CloudFront - DDoS and abuse protection
# Attaches to CloudFront edge - no DNS or origin changes required

resource "aws_wafv2_web_acl" "tellerstech" {
  name        = "tellerstech-cloudfront-waf"
  description = "WAF for www.tellerstech.com CloudFront distribution"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Rule 1: Rate limit wp-login.php (brute force protection)
  rule {
    name     = "RateLimitWPLogin"
    priority = 1

    override_action {
      none {}
    }

    statement {
      rate_based_statement {
        limit              = 100 # requests per 5 minutes
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/wp-login.php"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitWPLogin"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: Rate limit wp-admin (authenticated abuse protection)
  rule {
    name     = "RateLimitWPAdmin"
    priority = 2

    override_action {
      none {}
    }

    statement {
      rate_based_statement {
        limit              = 500 # requests per 5 minutes (higher for admin usage)
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/wp-admin"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitWPAdmin"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: Rate limit wp-json API
  rule {
    name     = "RateLimitWPAPI"
    priority = 3

    override_action {
      none {}
    }

    statement {
      rate_based_statement {
        limit              = 300 # requests per 5 minutes
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/wp-json"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitWPAPI"
      sampled_requests_enabled   = true
    }
  }

  # Rule 4: Rate limit RSS feeds (scraper abuse protection)
  rule {
    name     = "RateLimitRSSFeeds"
    priority = 4

    override_action {
      none {}
    }

    statement {
      rate_based_statement {
        limit              = 200 # requests per 5 minutes
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/feed"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitRSSFeeds"
      sampled_requests_enabled   = true
    }
  }

  # Rule 5: AWS Managed Rules - Common Rule Set (OWASP Top 10)
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        # Exclude rules that might block legitimate WordPress requests
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
        rule_action_override {
          name = "CrossSiteScripting_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rule 6: AWS Managed Rules - Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 11

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rule 7: AWS Managed Rules - IP Reputation List
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 12

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  # Rule 8: Block requests with no User-Agent (bot traffic)
  rule {
    name     = "BlockNoUserAgent"
    priority = 20

    action {
      block {}
    }

    statement {
      size_constraint_statement {
        comparison_operator = "EQ"
        size                = 0
        field_to_match {
          single_header {
            name = "user-agent"
          }
        }
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "BlockNoUserAgent"
      sampled_requests_enabled   = true
    }
  }

  # Global rate limit - overall site protection
  rule {
    name     = "GlobalRateLimit"
    priority = 99

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000 # requests per 5 minutes per IP
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "GlobalRateLimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "TellersTechWAF"
    sampled_requests_enabled   = true
  }

  tags = merge(
    var.core_tags,
    {
      "Name" = "TellersTech.com WAF"
    },
  )
}

# CloudWatch Log Group for WAF logs (optional but recommended)
resource "aws_cloudwatch_log_group" "waf_logs" {
  name              = "aws-waf-logs-tellerstech"
  retention_in_days = 30

  tags = var.core_tags
}

resource "aws_wafv2_web_acl_logging_configuration" "tellerstech" {
  log_destination_configs = [aws_cloudwatch_log_group.waf_logs.arn]
  resource_arn            = aws_wafv2_web_acl.tellerstech.arn

  # Don't log full request body (reduces costs and PII exposure)
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}
