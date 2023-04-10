######################################################
# Backend
######################################################
terraform {
  cloud {
    organization = "WBAT"

    workspaces {
      name = "wbat-terraform-github"
    }
  }
}

######################################################
# Providers
######################################################
provider "github" {
  token = var.github_oauth_token
  owner = "wbat"
}

######################################################
# Modules
######################################################
module "repos" {
  source = "./repos"

  email_address = var.email_address
}
