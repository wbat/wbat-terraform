module "iam" {
  source = "./iam"

  core_tags = var.core_tags

  terraform_cloud_external_id = var.terraform_cloud_external_id
  briefs_bucket_arn           = aws_s3_bucket.briefs.arn
  briefs_bucket_id            = aws_s3_bucket.briefs.id
}

module "acm" {
  source = "./acm"

  core_tags = var.core_tags
}

module "cloudfront" {
  source = "./cloudfront"

  core_tags                = var.core_tags
  acm_certificate_arn      = module.acm.www_tellerstech_certificate_arn
  cloudfront_origin_secret = var.cloudfront_origin_secret
  enable_legacy_cdn        = var.enable_legacy_cdn
  enable_waf               = var.enable_waf
  # origin_fqdn defaults to origin.tellerstech.com (managed in BIND)
}

module "cloudwatch" {
  source = "./cloudwatch"

  core_tags                  = var.core_tags
  billing_alert_email        = var.billing_alert_email
  billing_threshold_warning  = var.billing_threshold_warning
  billing_threshold_critical = var.billing_threshold_critical
}

module "ses" {
  source = "./ses"

  core_tags         = var.core_tags
  tellerstech_email = var.tellerstech_email
}
