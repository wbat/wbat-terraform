######################################################
# Backend
######################################################
terraform {
  cloud {
    organization = "WBAT"

    workspaces {
      name = "wbat-terraform-aws"
    }
  }
}

######################################################
# Providers
#####################################################
provider "aws" {
  assume_role {
    role_arn     = "arn:aws:iam::708113892725:role/TerraformCloud"
    session_name = "TerraformCloud"
    external_id  = local.terraform_cloud_external_id
  }

  # For Importing
  # profile = "wbat"

  region              = "us-east-1"
  allowed_account_ids = [708113892725]
}

######################################################
# Global Modules
######################################################
module "global" {
  source = "./global"

  core_tags = local.tags

  terraform_cloud_external_id = local.terraform_cloud_external_id
  cloudfront_origin_secret    = var.cloudfront_origin_secret
  enable_legacy_cdn           = false # Set to true to re-enable cdn.aws.tellerstech.com
  enable_waf                  = false # Set to true to enable WAF (~$5-10/month)

  # Billing alerts - uses email_address from credentials.tf
  billing_alert_email        = var.email_address
  billing_threshold_warning  = 75  # Alert at $75
  billing_threshold_critical = 100 # Critical at $100
}

######################################################
# Regional Modules
######################################################
module "us-east-1" {
  source = "./us-east-1"

  primary_instance_type   = local.primary_instance_type
  secondary_instance_type = local.secondary_instance_type

  instance_profile-WBAT_Main_Server      = module.global.instance_profile-WBAT_Main_Server
  instance_profile_name-WBAT_Main_Server = module.global.instance_profile_name-WBAT_Main_Server

  core_tags = local.tags
}
