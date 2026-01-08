terraform {
  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = "~>0.60"
    }
  }
  required_version = ">= 1.14"
}
