locals {
  tags = merge(
    {
      "management" = "terraform"
    },
    {
      "scm:repo" = "wbat/wbat-terraform"
    }
  )
}
