# Operational identifiers for the two "pet" servers.
#
# These exist so the values an operator needs during an incident (which instance ID to
# open an SSM session against, which private IP the vhost reconciler expects as its
# arrival address, which launch template a DR rebuild would use) can be read from
# `terraform output` instead of clicked out of the console. Values live in TFC state,
# never in this public repo.

output "primary_instance_id" {
  value       = aws_instance.primary.id
  description = "Instance ID of the primary server (WordPress/DNS). Use for SSM sessions."
}

output "secondary_instance_id" {
  value       = aws_instance.secondary.id
  description = "Instance ID of the secondary server (DNS)."
}

output "primary_private_ip" {
  value       = aws_instance.primary.private_ip
  description = "Private IP of the primary server. This is the arrival address the DirectAdmin Linked IP and nginx listen invariant must match (see aws/docs/nginx-vhost-catchall-regression.md)."
}

output "secondary_private_ip" {
  value       = aws_instance.secondary.private_ip
  description = "Private IP of the secondary server; its own arrival address."
}

output "primary_public_ip" {
  value       = aws_eip.primary.public_ip
  description = "Elastic IP of the primary server. EXPECTED_PUBLIC_IP in /etc/da-vhost-listen/vhost-listen.conf must equal this."
}

output "secondary_public_ip" {
  value       = aws_eip.secondary.public_ip
  description = "Elastic IP of the secondary server."
}

output "primary_ami_id" {
  value       = aws_ami.primary.id
  description = "AMI registered from the primary snapshot; the DR rebuild source."
}

output "secondary_ami_id" {
  value       = aws_ami.secondary.id
  description = "AMI registered from the secondary snapshot."
}

output "primary_ami_snapshot_id" {
  value       = data.aws_ebs_snapshot.primary.id
  description = "Snapshot backing primary_ami_id. Compare against the live root volume size before trusting a DR rebuild."
}

output "secondary_ami_snapshot_id" {
  value       = data.aws_ebs_snapshot.secondary.id
  description = "Snapshot backing secondary_ami_id."
}

# These two were added while the snapshot source was pinned to the pre-shrink 300 GB
# fossil, to make that mismatch visible. The source now tracks the current DLM snapshots,
# so they should agree -- which is exactly why they are worth keeping: they turn "is the
# DR AMI built from the right disk?" into a standing check rather than a one-time fix.
output "primary_ami_snapshot_volume_size" {
  value       = data.aws_ebs_snapshot.primary.volume_size
  description = "Volume size (GiB) of the snapshot the primary AMI is built from."
}

output "primary_ami_snapshot_start_time" {
  value       = data.aws_ebs_snapshot.primary.start_time
  description = "When the snapshot behind the primary AMI was taken. DLM runs Mon/Wed/Fri at 06:00 UTC and retains 3, so anything older than about a week means the schedule has stopped. (DLM cron is UTC-only, so the policy's 2AM_ET name holds only under EDT; in winter it fires at 01:00 ET.)"
}

output "primary_root_volume_size" {
  value       = one(aws_instance.primary.root_block_device[*].volume_size)
  description = "Root volume size (GiB) of the running primary. If this differs from primary_ami_snapshot_volume_size the DR AMI is built from the wrong disk."
}

output "primary_launch_template_id" {
  value       = aws_launch_template.primary.id
  description = "Launch template for a primary rebuild."
}

output "secondary_launch_template_id" {
  value       = aws_launch_template.secondary.id
  description = "Launch template for a secondary rebuild."
}

output "primary_dlm_policy_id" {
  value       = aws_dlm_lifecycle_policy.primary.id
  description = "DLM policy taking the M/W/F primary snapshots at 06:00 UTC (3 retained). The 2AM_ET in its name holds only under EDT; DLM cron is UTC-only."
}

output "secondary_dlm_policy_id" {
  value       = aws_dlm_lifecycle_policy.secondary.id
  description = "DLM policy taking the secondary snapshots."
}

output "key_pair_name" {
  value       = aws_key_pair.wbat.key_name
  description = "EC2 key pair both instances are launched with."
}
