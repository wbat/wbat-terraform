variable "core_tags" {}
variable "terraform_cloud_external_id" {}
variable "briefs_bucket_arn" {
  description = "ARN of S3 bucket for On Call Brief backups (briefs/)."
  type        = string
}
variable "briefs_bucket_id" {
  description = "Name (ID) of the briefs bucket; for reference only."
  type        = string
}
