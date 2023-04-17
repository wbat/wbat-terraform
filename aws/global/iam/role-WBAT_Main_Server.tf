# AWS IAM Role for WBAT_Main_Server

resource "aws_iam_role" "WBAT_Main_Server" {
  name        = "WBAT_Main_Server"
  description = "Managed by Terraform."

  assume_role_policy = <<ASSUME_ROLE_POLICY
  {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
  }
ASSUME_ROLE_POLICY

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(
    var.core_tags,
    {
      "scm:file" = "aws/global/iam/role-WBAT_Main_Server.tf",
    },
  )
}

resource "aws_iam_role_policy_attachment" "WBAT_Main_Server-AmazonSSMManagedInstanceCore" {
  role       = aws_iam_role.WBAT_Main_Server.name
  policy_arn = data.aws_iam_policy.AmazonSSMManagedInstanceCore.arn
}

resource "aws_iam_instance_profile" "WBAT_Main_Server" {
  name = "WBAT_Main_Server"
  role = aws_iam_role.WBAT_Main_Server.name

  tags = merge(
    var.core_tags,
    {
      "scm:file" = "aws/global/iam/role-WBAT_Main_Server.tf",
    },
  )
}
