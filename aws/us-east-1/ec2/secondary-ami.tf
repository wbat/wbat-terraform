resource "aws_ami" "secondary" {
  name = "Secondary-M_W_F-4AM_ET"

  architecture     = "x86_64"
  root_device_name = "/dev/sda1"
  ena_support      = true

  sriov_net_support   = "simple"
  virtualization_type = "hvm"

  ebs_block_device {
    delete_on_termination = true
    device_name           = "/dev/sda1"
    iops                  = 3000
    snapshot_id           = data.aws_ebs_snapshot.secondary.id
    throughput            = 125
    volume_size           = data.aws_ebs_snapshot.secondary.volume_size
    volume_type           = "gp3"
  }

  tags = merge(
    var.core_tags,
    {
      Name       = "Secondary",
      "scm:file" = "aws/us-east-1/ec2/secondary-ami.tf",
    },
  )
}
