# User accounts for TerraformCloud

######################################################
# AWS
######################################################

resource "aws_iam_user" "TerraformCloud" {
  name          = "TerraformCloud"
  force_destroy = false

  # An access key ID was previously used as a tag *key* here ("AKIA...":
  # "TerraformCloud Access"), publishing it from this public repo. The tag is gone; the
  # ID remains in git history and in prior state versions.
  #
  # Rotation was considered and deliberately declined. The reasoning, so nobody has to
  # re-derive it:
  #
  #   - An access key ID is the non-secret half of the pair. AWS itself surfaces it in
  #     CloudTrail, the IAM console, and API error messages. The secret access key is
  #     the credential, and it was NEVER committed: the only match in full history is
  #     the tfe_variable declaration in tfc/, whose value is "" with
  #     ignore_changes = [value]. The real value lives only in the TFC "AWS Access"
  #     variable set.
  #   - The usual secondary worry -- that an AKIA ID reveals the account ID -- is moot
  #     here. aws/main.tf already contains the account number in allowed_account_ids
  #     and the assume-role ARN, so nothing incremental was disclosed.
  #
  # Reconsider if the secret is ever exposed, if the key appears in CloudTrail from an
  # unexpected source IP, or if this user gains permissions beyond sts:AssumeRole. The
  # user's inline policy below is the real control: the key alone can only assume the
  # TerraformCloud role, so it is worth keeping that scope narrow.
  #
  # Whatever key is current is recorded in TFC, not in a tag here.
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
