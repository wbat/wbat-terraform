variable "core_tags" {
  description = "Common tags (unused for Route53 records but kept for consistency)"
  default     = {}
}

variable "ec2_elastic_ip" {
  description = "Elastic IP address of the primary EC2 instance"
  type        = string
}
