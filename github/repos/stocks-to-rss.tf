module "stocks_to_rss" {
  source = "./modules/repository"

  name           = "stocks-to-rss"
  description    = "Stock Prices to RSS"
  default_branch = "master"
}
