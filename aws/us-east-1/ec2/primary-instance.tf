# Primary EC2 Instance - WordPress / DNS Server
# This is a "pet" server with persistent data - not ephemeral
resource "aws_instance" "primary" {
  ami                  = aws_ami.primary.id
  instance_type        = var.primary_instance_type
  key_name             = aws_key_pair.wbat.key_name
  iam_instance_profile = var.instance_profile_name-WBAT_Main_Server
  # Cutover instance i-0118b8ede80b52ef7 launched with EbsOptimized=false;
  # changing to true forces instance replacement.
  ebs_optimized = false
  monitoring    = false

  subnet_id                   = data.aws_subnet.selected.id
  vpc_security_group_ids      = [data.aws_security_group.default.id]
  associate_public_ip_address = true

  credit_specification {
    # Keep "unlimited" so the WordPress server can burst without throttling.
    # Matches the live instance; "standard" here would downgrade it on apply.
    cpu_credits = "unlimited"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 200
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    kms_key_id            = var.kms_key-ebs-arn
    delete_on_termination = true
  }

  # Prevent accidental termination
  disable_api_termination = true

  # The Name tag must stay exactly "WBAT Primary Server": the DLM policy selects this
  # instance by target_tags on that value, so renaming it silently stops snapshots.
  # core_tags is merged in for cost allocation and provenance, matching every other
  # resource in this repo; it was the only omission, which left the account's two most
  # expensive resources outside the Application/Environment cost split. Because
  # copy_tags is on, new DLM snapshots inherit these tags too.
  tags = merge(
    var.core_tags,
    {
      "Name"     = "WBAT Primary Server"
      "scm:file" = "aws/us-east-1/ec2/primary-instance.tf"
    },
  )

  volume_tags = merge(
    var.core_tags,
    {
      "Name"     = "WBAT Primary Server"
      "scm:file" = "aws/us-east-1/ec2/primary-instance.tf"
    },
  )

  # Safety: Prevent Terraform from destroying this instance
  lifecycle {
    prevent_destroy = true
    # Ignore AMI changes - we manage AMIs separately via DLM
    ignore_changes = [ami]
  }
}
