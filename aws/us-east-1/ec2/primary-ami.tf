resource "aws_ami" "primary" {
  name = "Primary-M_W_F-2AM_ET"

  architecture     = "x86_64"
  root_device_name = "/dev/sda1"
  ena_support      = true

  sriov_net_support   = "simple"
  virtualization_type = "hvm"

  ebs_block_device {
    delete_on_termination = true
    device_name           = "/dev/sda1"
    encrypted             = data.aws_ebs_snapshot.primary.encrypted
    iops                  = 3000
    snapshot_id           = data.aws_ebs_snapshot.primary.id
    throughput            = 125
    volume_size           = data.aws_ebs_snapshot.primary.volume_size
    volume_type           = "gp3"
  }

  tags = merge(
    var.core_tags,
    {
      Name       = "Primary",
      "scm:file" = "aws/us-east-1/ec2/primary-ami.tf",
    },
  )
}
