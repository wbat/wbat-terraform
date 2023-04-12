module "ec2" {
  source = "./ec2"

  core_tags = var.core_tags
}
