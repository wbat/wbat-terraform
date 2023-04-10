module "iam" {

  source = "./iam"

  core_tags = var.core_tags

  terraform_cloud_external_id = var.terraform_cloud_external_id
}
