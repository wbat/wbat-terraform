terraform {
  required_providers {
    github = {
      source                = "integrations/github"
      version               = "~>6.0"
      configuration_aliases = [github.tellerstechorg]
    }
  }
  required_version = ">= 1.15.0"
}
