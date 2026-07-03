module "stripe_terminal" {
  source = "./modules/repository"

  name           = "stripe-terminal"
  description    = "Stripe Terminal"
  default_branch = "master"
}
