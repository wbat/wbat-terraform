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

  # IMDSv2 is NOT enforced here, and this block exists to say so deliberately rather than
  # by omission. "optional" is the current live setting, so declaring it changes nothing;
  # it makes enforcing a one-word diff, and it stops the next reader assuming the gap was
  # an oversight.
  #
  # Enforcing would be the right thing on the merits. Unauthenticated IMDSv1 is what turns
  # a server-side request forgery in any hosted site into instance-role credentials, and
  # that matters more than usual here: this profile can send SES mail and invalidate
  # CloudFront, and ~91 WordPress sites share the box.
  #
  # It is blocked by a named live consumer. Installatron's auto-updater
  # (/etc/cron.d/installatron -> lib/cron.updater.sh, minute 33 of local hours 1/7/13/19)
  # makes 6 unauthenticated metadata calls per run, four times a day, 9 on the 05:33 UTC
  # run that also walks the hosted sites. Measured over 7 days: 27 runs, 27 non-zero
  # MetadataNoToken buckets, no other source. http_tokens = "required" applies immediately
  # via ModifyInstanceMetadataOptions with no reboot and no grace period, so flipping this
  # today breaks WordPress auto-updates across every hosted site at the next burst.
  #
  # Installatron is ionCube-encoded vendor code already at the latest version, so this is a
  # vendor request rather than a local fix. Flip to "required" once it reads IMDS with a
  # token, or once it is retired. The secondary already enforces -- it is flat zero because
  # Installatron is not installed there. See aws/docs/imdsv2-enforcement.md.
  #
  # hop_limit 1 is also already live, and correct: the caller is a root cron job invoking a
  # local binary, not a containerised process. It would need 2 only if something on the box
  # reached IMDS from inside a container.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
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
