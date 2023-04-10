######################################################
# Backend
######################################################
terraform {
  cloud {
    organization = "WBAT"

    workspaces {
      name = "wbat-terraform-tfc"
    }
  }
}

######################################################
# Providers
######################################################
provider "tfe" {
  token = var.tfc_token
}
