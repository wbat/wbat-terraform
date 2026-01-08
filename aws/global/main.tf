module "iam" {
  source = "./iam"

  core_tags = var.core_tags

  terraform_cloud_external_id = var.terraform_cloud_external_id
}

module "route53" {
  source = "./route53"

  core_tags      = var.core_tags
  ec2_elastic_ip = var.ec2_elastic_ip
}

module "acm" {
  source = "./acm"

  core_tags = var.core_tags
}

module "cloudfront" {
  source = "./cloudfront"

  core_tags                = var.core_tags
  origin_fqdn              = module.route53.origin_fqdn
  acm_certificate_arn      = module.acm.www_tellerstech_certificate_arn
  cloudfront_origin_secret = var.cloudfront_origin_secret
}
