# AWS IAM Role for TerraformCloud

resource "aws_iam_role" "TerraformCloud" {
  name        = "TerraformCloud"
  description = "Managed by Terraform."

  assume_role_policy = <<ASSUME_ROLE_POLICY
  {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/TerraformCloud"
            },
            "Action": "sts:AssumeRole",
            "Condition": {
                "StringEquals": {
                    "sts:ExternalId": "${var.terraform_cloud_external_id}"
                }
            }
        }
    ]
  }
ASSUME_ROLE_POLICY

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(
    local.tags,
    {
      "scm:file" = "aws/global/iam/role-TerraformCloud.tf",
    },
  )
}

resource "aws_iam_role_policy_attachment" "TerraformCloud-Administrator" {
  role       = aws_iam_role.TerraformCloud.name
  policy_arn = data.aws_iam_policy.administrator_access.arn
}
