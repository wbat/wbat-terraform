# User accounts for TerraformCloud

######################################################
# AWS
######################################################

resource "aws_iam_user" "TerraformCloud" {
  name          = "TerraformCloud"
  force_destroy = false

  # An access key ID was previously used as a tag *key* here ("AKIA...":
  # "TerraformCloud Access"), which published it from this public repo. Removing it
  # stops the leak spreading but does NOT undo it: the ID remains in git history and in
  # every prior state version. The key itself still has to be rotated -- create a new
  # one, update the "AWS Access" variable set in TFC, confirm a plan succeeds, then
  # delete the old key. Record which key is current in TFC, not in a tag.
  tags = merge(
    var.core_tags,
    {
      "scm:file" = "aws/global/iam/user-TerraformCloud.tf",
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
