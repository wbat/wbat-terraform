variable "core_tags" {}
variable "primary_public_ip" {
  description = "Elastic IP of the primary server (server.wbat.net)"
  type        = string
}

variable "secondary_public_ip" {
  description = "Elastic IP of the secondary server (server2.wbat.net)"
  type        = string
}

variable "da_panel_allowed_cidrs" {
  description = "label => CIDR allowed to reach the DirectAdmin panel on 2222"
  type        = map(string)
  default     = {}
}
