resource "aws_dlm_lifecycle_policy" "primary" {
  description        = "Primary-M_W_F-2AM_ET"
  execution_role_arn = data.aws_iam_role.AWSDataLifecycleManagerDefaultRole.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]

    parameters {
      exclude_boot_volume = false
      no_reboot           = false
    }

    schedule {
      name = "M_W_F-2AM_ET"

      create_rule {
        cron_expression = "cron(00 06 ? * MON,WED,FRI *)"
      }

      retain_rule {
        count = 12
      }

      tags_to_add = {
      }

      variable_tags = {
        "instance-id" = "$(instance-id)"
        "timestamp"   = "$(timestamp)"
      }

      copy_tags = true
    }

    target_tags = {
      Name = "WBAT Primary Server"
    }
  }

  tags = merge(
    var.core_tags,
    {
      Name       = "Primary-M_W_F-2AM_ET",
      "scm:file" = "aws/us-east-1/ec2/primary-lifecycle_manager.tf",
    },
  )
}
