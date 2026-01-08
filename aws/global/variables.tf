variable "core_tags" {}
variable "terraform_cloud_external_id" {}

variable "ec2_elastic_ip" {
  description = "Elastic IP address of the primary EC2 instance"
  type        = string
}

variable "cloudfront_origin_secret" {
  description = "Secret header value to verify requests come from CloudFront (optional)"
  type        = string
  sensitive   = true
  default     = ""
}
