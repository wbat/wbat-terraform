module "ec2" {
  source = "./ec2"

  core_tags       = var.core_tags
  kms_key-ebs-arn = module.kms.kms_key-ebs-arn

  primary_instance_type   = var.primary_instance_type
  secondary_instance_type = var.secondary_instance_type

  instance_profile-WBAT_Main_Server      = var.instance_profile-WBAT_Main_Server
  instance_profile_name-WBAT_Main_Server = var.instance_profile_name-WBAT_Main_Server

  host_health_alerts_topic_arn = var.host_health_alerts_topic_arn
}

module "kms" {
  source = "./kms"

  core_tags = var.core_tags
}

module "sg" {
  source = "./sg"

  # server.wbat.net and server2.wbat.net resolve to these, so a panel session
  # opened from one box to the other by hostname arrives from the public
  # address rather than the private one. Taken from the managed EIPs so the
  # allowlist follows an address change instead of going stale.
  primary_public_ip   = module.ec2.primary_public_ip
  secondary_public_ip = module.ec2.secondary_public_ip

  da_panel_allowed_cidrs = var.da_panel_allowed_cidrs

  core_tags = var.core_tags
}

module "vpc" {
  source = "./vpc"

  core_tags = var.core_tags
}
