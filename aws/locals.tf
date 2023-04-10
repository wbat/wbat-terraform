locals {
  env = "prod"
  app = "wbat"

  terraform_cloud_external_id = "7843003F-57C4-46D2-BAFD-1880507A01C7"

  tags = {
    "scm:repo"    = "wbat/wbat-terraform"
    "management"  = "terraform"
    "Application" = local.app
    "Environment" = local.env
  }
}
