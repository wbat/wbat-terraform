locals {
  env = "prod"
  app = "wbat"

  terraform_cloud_external_id = "7843003F-57C4-46D2-BAFD-1880507A01C7"

  primary_instance_type   = "t3a.medium"
  secondary_instance_type = "t3a.micro"

  # Primary EC2 Elastic IP for CloudFront origin
  ec2_elastic_ip = "44.214.133.234"

  tags = {
    "scm:repo"    = "wbat/wbat-terraform"
    "management"  = "terraform"
    "Application" = local.app
    "Environment" = local.env
  }
}
