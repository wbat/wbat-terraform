######################################################
# Root outputs
#
# Terraform does not surface child-module outputs automatically, so without this file
# `terraform output` on the wbat-terraform-aws workspace returns an empty object even
# though ./global and ./us-east-1 both declare outputs. Everything an operator would
# otherwise hunt for in the AWS console is re-exported here.
#
# These declarations are safe in a public repo: the values are resolved at apply time
# and stored in HCP Terraform state, not in git.
######################################################

######################################################
# CloudFront / ACM (www.tellerstech.com)
######################################################
output "cloudfront_distribution_id" {
  value       = module.global.cloudfront_distribution_id
  description = "CloudFront distribution ID for www.tellerstech.com; the target for cache invalidations."
}

output "cloudfront_distribution_domain_name" {
  value       = module.global.cloudfront_distribution_domain_name
  description = "CloudFront domain name - CNAME www.tellerstech.com to this in BIND."
}

output "acm_validation_records" {
  value       = module.global.acm_validation_records
  description = "CNAME records BIND must serve for certificate validation (keep permanently for auto-renewal)."
}

output "origin_fqdn" {
  value       = module.global.origin_fqdn
  description = "Origin FQDN CloudFront sends to (managed in BIND)."
}

######################################################
# S3
######################################################
output "briefs_bucket_id" {
  value       = module.global.briefs_bucket_id
  description = "S3 bucket for briefs backup; set BRIEFS_S3_URI=s3://<this_value>/ on the server."
}

output "briefs_bucket_arn" {
  value       = module.global.briefs_bucket_arn
  description = "ARN of the briefs backup bucket (for IAM)."
}

output "directadmin_backups_bucket_id" {
  value       = module.global.directadmin_backups_bucket_id
  description = "S3 bucket for DirectAdmin Enhanced Backups; configure this bucket name in DA."
}

output "directadmin_backup_iam_user" {
  value       = module.global.directadmin_backup_iam_user
  description = "IAM user DirectAdmin uses for S3 backups; create an access key for it and paste into DA."
}

######################################################
# SES
######################################################
output "ses_da_gmail_forward_secret_name" {
  value       = module.global.ses_da_gmail_forward_secret_name
  description = "Secrets Manager secret for the DirectAdmin to SES Gmail pipe (MX stays on DA)."
}

output "ses_da_gmail_forward_secret_arn" {
  value       = module.global.ses_da_gmail_forward_secret_arn
  description = "Secrets Manager ARN for the DirectAdmin to SES Gmail pipe."
}

######################################################
# IAM
######################################################
output "instance_profile_name-WBAT_Main_Server" {
  value       = module.global.instance_profile_name-WBAT_Main_Server
  description = "Instance profile attached to both servers (SSM, SES send, CloudFront invalidation)."
}

######################################################
# EC2 (us-east-1)
#
# The two servers are pets, so their identifiers are incident-response inputs: which
# instance to open an SSM session against, and which addresses the DirectAdmin Linked
# IP / nginx listen invariant must agree with (aws/docs/nginx-vhost-catchall-regression.md).
######################################################
output "primary_instance_id" {
  value       = module.us-east-1.primary_instance_id
  description = "Instance ID of the primary server (WordPress/DNS). Use for SSM sessions."
}

output "secondary_instance_id" {
  value       = module.us-east-1.secondary_instance_id
  description = "Instance ID of the secondary server (DNS)."
}

output "primary_private_ip" {
  value       = module.us-east-1.primary_private_ip
  description = "Arrival (private) IP of the primary server; must match the DirectAdmin Linked IP and every nginx listen."
}

output "secondary_private_ip" {
  value       = module.us-east-1.secondary_private_ip
  description = "Arrival (private) IP of the secondary server."
}

output "primary_public_ip" {
  value       = module.us-east-1.primary_public_ip
  description = "Elastic IP of the primary server; EXPECTED_PUBLIC_IP in /etc/da-vhost-listen/vhost-listen.conf must equal this."
}

output "secondary_public_ip" {
  value       = module.us-east-1.secondary_public_ip
  description = "Elastic IP of the secondary server."
}

######################################################
# DR / backups
######################################################
output "primary_ami_id" {
  value       = module.us-east-1.primary_ami_id
  description = "AMI registered from the primary snapshot; the DR rebuild source."
}

output "secondary_ami_id" {
  value       = module.us-east-1.secondary_ami_id
  description = "AMI registered from the secondary snapshot."
}

output "primary_ami_snapshot_id" {
  value       = module.us-east-1.primary_ami_snapshot_id
  description = "Snapshot backing the primary AMI."
}

output "secondary_ami_snapshot_id" {
  value       = module.us-east-1.secondary_ami_snapshot_id
  description = "Snapshot backing the secondary AMI."
}

output "primary_ami_snapshot_volume_size" {
  value       = module.us-east-1.primary_ami_snapshot_volume_size
  description = "Volume size (GiB) of the snapshot the primary AMI is built from."
}

output "primary_root_volume_size" {
  value       = module.us-east-1.primary_root_volume_size
  description = "Root volume size (GiB) of the running primary. If this differs from primary_ami_snapshot_volume_size the DR AMI is stale."
}

output "primary_launch_template_id" {
  value       = module.us-east-1.primary_launch_template_id
  description = "Launch template for a primary rebuild."
}

output "secondary_launch_template_id" {
  value       = module.us-east-1.secondary_launch_template_id
  description = "Launch template for a secondary rebuild."
}

output "primary_dlm_policy_id" {
  value       = module.us-east-1.primary_dlm_policy_id
  description = "DLM policy taking the M/W/F 2AM ET primary snapshots (3 retained)."
}

output "secondary_dlm_policy_id" {
  value       = module.us-east-1.secondary_dlm_policy_id
  description = "DLM policy taking the secondary snapshots."
}

output "key_pair_name" {
  value       = module.us-east-1.key_pair_name
  description = "EC2 key pair both instances are launched with."
}

######################################################
# Network
######################################################
output "vpc_id" {
  value       = module.us-east-1.vpc_id
  description = "ID of the Main VPC."
}

output "vpc_cidr_block" {
  value       = module.us-east-1.vpc_cidr_block
  description = "CIDR block of the Main VPC."
}

output "internet_gateway_id" {
  value       = module.us-east-1.internet_gateway_id
  description = "ID of the Internet Gateway."
}

output "subnet_ids" {
  value       = module.us-east-1.subnet_ids
  description = "Map of subnet IDs by availability zone."
}

output "kms_key_ebs_arn" {
  value       = module.us-east-1.kms_key_ebs_arn
  description = "ARN of the CMK the root volumes are encrypted with."
}
