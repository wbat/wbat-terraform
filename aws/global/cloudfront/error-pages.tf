# Private S3 origin for CloudFront custom error pages (www.tellerstech.com).
# HTML lives under errors/; objects are keyed as errors/*.html so CF can serve
# /errors/*.html via OAC. Only 5xx are remapped via custom_error_response —
# 404/403 stay with WordPress / nginx so the full-chrome TT 404 remains.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "cf_errors" {
  bucket = "wbat-tellerstech-cf-errors-${data.aws_caller_identity.current.account_id}"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "tellerstech-cloudfront-error-pages"
      "scm:file" = "aws/global/cloudfront/error-pages.tf"
    },
  )
}

resource "aws_s3_bucket_versioning" "cf_errors" {
  bucket = aws_s3_bucket.cf_errors.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cf_errors" {
  bucket = aws_s3_bucket.cf_errors.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cf_errors" {
  bucket = aws_s3_bucket.cf_errors.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "cf_errors" {
  name                              = "tellerstech-cf-errors-oac"
  description                       = "OAC for www.tellerstech.com custom error pages"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "cf_errors" {
  bucket = aws_s3_bucket.cf_errors.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipalRead"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.cf_errors.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.tellerstech_website.arn
          }
        }
      }
    ]
  })
}

locals {
  cf_error_pages = {
    "errors/403.html" = "${path.module}/errors/403.html"
    "errors/404.html" = "${path.module}/errors/404.html"
    "errors/503.html" = "${path.module}/errors/503.html"
  }
}

resource "aws_s3_object" "cf_errors" {
  for_each = local.cf_error_pages

  bucket       = aws_s3_bucket.cf_errors.id
  key          = each.key
  source       = each.value
  etag         = filemd5(each.value)
  content_type = "text/html; charset=utf-8"
}
