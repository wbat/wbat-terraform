module "osticket_rest_api" {
  source = "./modules/repository"

  name           = "osticket-rest-api"
  description    = "osTicket REST API"
  default_branch = "master"
}
