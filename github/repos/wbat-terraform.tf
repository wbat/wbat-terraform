module "wbat_terraform" {
  source = "./modules/repository"

  name        = "wbat-terraform"
  description = "WBAT Terraform Repo"

  topics = [
    "aws",
    "hcl",
    "terraform",
    "terraform-aws",
    "terraform-cloud",
    "terraform-github",
  ]

  manage_branch_protection = true
  required_status_check_contexts = [
    # TFC
    "Terraform Cloud/WBAT/wbat-terraform-aws",
    "Terraform Cloud/WBAT/wbat-terraform-github",
    "Terraform Cloud/WBAT/wbat-terraform-tfc",

    # Github Actions (version-independent names; see aws/docs/terraform-version-upgrade.md)
    "Format",
    "Validate (aws)",
    "Validate (github)",
    "Validate (tfc)",
  ]
}
