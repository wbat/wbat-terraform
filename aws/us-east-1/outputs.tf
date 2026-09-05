######################################################
# EC2
######################################################
output "primary_instance_id" {
  value       = module.ec2.primary_instance_id
  description = "Instance ID of the primary server (WordPress/DNS)."
}

output "secondary_instance_id" {
  value       = module.ec2.secondary_instance_id
  description = "Instance ID of the secondary server (DNS)."
}

output "primary_private_ip" {
  value       = module.ec2.primary_private_ip
  description = "Private (arrival) IP of the primary server."
}

output "secondary_private_ip" {
  value       = module.ec2.secondary_private_ip
  description = "Private (arrival) IP of the secondary server."
}

output "primary_public_ip" {
  value       = module.ec2.primary_public_ip
  description = "Elastic IP of the primary server."
}

output "secondary_public_ip" {
  value       = module.ec2.secondary_public_ip
  description = "Elastic IP of the secondary server."
}

output "primary_ami_id" {
  value       = module.ec2.primary_ami_id
  description = "AMI registered from the primary snapshot."
}

output "secondary_ami_id" {
  value       = module.ec2.secondary_ami_id
  description = "AMI registered from the secondary snapshot."
}

output "primary_ami_snapshot_id" {
  value       = module.ec2.primary_ami_snapshot_id
  description = "Snapshot backing the primary AMI."
}

output "secondary_ami_snapshot_id" {
  value       = module.ec2.secondary_ami_snapshot_id
  description = "Snapshot backing the secondary AMI."
}

output "primary_ami_snapshot_volume_size" {
  value       = module.ec2.primary_ami_snapshot_volume_size
  description = "Volume size (GiB) of the snapshot the primary AMI is built from."
}

output "primary_root_volume_size" {
  value       = module.ec2.primary_root_volume_size
  description = "Root volume size (GiB) of the running primary; a mismatch with the snapshot size means the DR AMI is stale."
}

output "primary_launch_template_id" {
  value       = module.ec2.primary_launch_template_id
  description = "Launch template for a primary rebuild."
}

output "secondary_launch_template_id" {
  value       = module.ec2.secondary_launch_template_id
  description = "Launch template for a secondary rebuild."
}

output "primary_dlm_policy_id" {
  value       = module.ec2.primary_dlm_policy_id
  description = "DLM policy taking the primary snapshots."
}

output "secondary_dlm_policy_id" {
  value       = module.ec2.secondary_dlm_policy_id
  description = "DLM policy taking the secondary snapshots."
}

output "key_pair_name" {
  value       = module.ec2.key_pair_name
  description = "EC2 key pair both instances are launched with."
}

######################################################
# VPC
######################################################
output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "ID of the Main VPC."
}

output "vpc_cidr_block" {
  value       = module.vpc.vpc_cidr_block
  description = "CIDR block of the Main VPC."
}

output "internet_gateway_id" {
  value       = module.vpc.internet_gateway_id
  description = "ID of the Internet Gateway."
}

output "subnet_ids" {
  value       = module.vpc.subnet_ids
  description = "Map of subnet IDs by availability zone."
}

######################################################
# KMS
######################################################
output "kms_key_ebs_arn" {
  value       = module.kms.kms_key-ebs-arn
  description = "ARN of the CMK the root volumes are encrypted with."
}
