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

provider "github" {
  alias = "tellerstechorg"
  token = var.github_oauth_token
  owner = "TellersTechOrg"
}

######################################################
# Modules
######################################################
module "repos" {
  source = "./repos"

  personal_email = var.personal_email

  providers = {
    github                = github
    github.tellerstechorg = github.tellerstechorg
  }
}
