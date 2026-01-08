######################################################
# Imports
# After successful import, comment out or remove these blocks
######################################################
# import {
#   to = module.global.module.cloudfront.aws_cloudfront_distribution.cdn_legacy[0]
#   id = "E1BJFU3JD7PL7F"
# }

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
}

######################################################
# Regional Modules
######################################################
module "us-east-1" {
  source = "./us-east-1"

  primary_instance_type   = local.primary_instance_type
  secondary_instance_type = local.secondary_instance_type

  instance_profile-WBAT_Main_Server = module.global.instance_profile-WBAT_Main_Server

  core_tags = local.tags
}
