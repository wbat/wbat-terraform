resource "aws_launch_template" "secondary" {
  name = "WBAT_Secondary"

  disable_api_stop                     = true
  disable_api_termination              = true
  ebs_optimized                        = "true"
  image_id                             = aws_ami.secondary.id
  instance_initiated_shutdown_behavior = "stop"
  instance_type                        = var.secondary_instance_type
  key_name                             = aws_key_pair.wbat.key_name

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      delete_on_termination = "true"
      encrypted             = data.aws_ebs_snapshot.secondary.encrypted
      iops                  = 3000
      kms_key_id            = var.kms_key-ebs-arn
      snapshot_id           = data.aws_ebs_snapshot.secondary.id
      throughput            = 125
      volume_size           = data.aws_ebs_snapshot.secondary.volume_size
      volume_type           = "gp3"
    }
  }

  capacity_reservation_specification {
    capacity_reservation_preference = "open"
  }

  credit_specification {
    cpu_credits = "unlimited"
  }

  hibernation_options {
    configured = false
  }

  iam_instance_profile {
    arn = var.instance_profile-WBAT_Main_Server
  }

  maintenance_options {
    auto_recovery = "default"
  }

  monitoring {
    enabled = false
  }

  network_interfaces {
    associate_public_ip_address = "true"
    delete_on_termination       = "true"
    device_index                = 0
    ipv4_address_count          = 0
    ipv4_prefix_count           = 0
    ipv6_address_count          = 0
    ipv6_prefix_count           = 0
    network_card_index          = 0
    security_groups = [
      data.aws_security_group.default.id,
    ]
    subnet_id = data.aws_subnet.selected.id
  }

  placement {
    partition_number = 0
    tenancy          = "default"
  }

  private_dns_name_options {
    enable_resource_name_dns_a_record    = false
    enable_resource_name_dns_aaaa_record = false
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      "Name" = "WBAT Secondary Server"
    }
  }

  tags = merge(
    var.core_tags,
    {
      Name       = "WBAT_Secondary",
      "scm:file" = "aws/us-east-1/ec2/secondary-launch_template.tf",
    },
  )
}
