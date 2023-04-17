resource "aws_kms_key" "ebs" {
  description = "WBAT's ebs Key"

  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"

  bypass_policy_lockout_safety_check = true
  deletion_window_in_days            = 10

  tags = merge(
    var.core_tags,
    {
      Name       = "ebs",
      "scm:file" = "aws/us-east-1/kms/ebs.tf",
    },
  )
}
