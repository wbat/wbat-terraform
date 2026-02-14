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

# CloudFront invalidation permissions for deploy workflows
resource "aws_iam_role_policy" "WBAT_Main_Server-CloudFrontInvalidation" {
  name = "CloudFrontInvalidation"
  role = aws_iam_role.WBAT_Main_Server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudfront:CreateInvalidation",
        "cloudfront:GetInvalidation",
        "cloudfront:ListDistributions"
      ]
      Resource = "*"
    }]
  })
}

# S3 briefs backup: sync briefs/ from EC2 (On Call Brief pipeline)
resource "aws_iam_role_policy" "WBAT_Main_Server-BriefsBackup" {
  name = "BriefsBackup"
  role = aws_iam_role.WBAT_Main_Server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = var.briefs_bucket_arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${var.briefs_bucket_arn}/*"
      }
    ]
  })
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
