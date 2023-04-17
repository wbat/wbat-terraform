module "ec2" {
  source = "./ec2"

  core_tags       = var.core_tags
  kms_key-ebs-arn = module.kms.kms_key-ebs-arn

  primary_instance_type   = var.primary_instance_type
  secondary_instance_type = var.secondary_instance_type

  instance_profile-WBAT_Main_Server = var.instance_profile-WBAT_Main_Server
}

module "kms" {
  source = "./kms"

  core_tags = var.core_tags
}
