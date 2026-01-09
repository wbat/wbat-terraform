module "iam" {
  source = "./iam"

  core_tags = var.core_tags

  terraform_cloud_external_id = var.terraform_cloud_external_id
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
