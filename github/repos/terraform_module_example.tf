# TellersTechOrg/terraform_module_example — uses the TellersTechOrg provider alias.
module "terraform_module_example" {
  source = "./modules/repository"

  providers = {
    github = github.tellerstechorg
  }

  name        = "terraform_module_example"
  description = "An Example of a Terraform Module"
  has_wiki    = false
}
