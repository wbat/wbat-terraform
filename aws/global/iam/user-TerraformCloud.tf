# User accounts for TerraformCloud

######################################################
# AWS
######################################################

resource "aws_iam_user" "TerraformCloud" {
  name          = "TerraformCloud"
  force_destroy = false

  tags = merge(
    local.tags,
    {
      "scm:file"             = "aws/global/iam/user-TerraformCloud.tf",
      "AKIA2JXXAQV2R2D3CCEP" = "TerraformCloud Access"
    },
  )
}

resource "aws_iam_user_policy" "TerraformCloud" {
  name = "TerraformCloud-policy"
  user = aws_iam_user.TerraformCloud.name

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ],
            "Resource": "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/TerraformCloud"
        }
    ]
}
EOF
}
