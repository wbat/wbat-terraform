variable "core_tags" {}
variable "primary_instance_type" {}
variable "secondary_instance_type" {}
variable "instance_profile-WBAT_Main_Server" {}
variable "instance_profile_name-WBAT_Main_Server" {}
variable "host_health_alerts_topic_arn" {
  type        = string
  description = "SNS topic ARN for EC2 status-check / host-health alarms"
}
variable "da_panel_allowed_cidrs" {
  type    = map(string)
  default = {}
}
