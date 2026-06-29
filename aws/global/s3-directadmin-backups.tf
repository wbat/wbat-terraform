# S3 bucket + IAM user for DirectAdmin remote (Enhanced) backups.
#
# DirectAdmin can write backups straight to S3 (Admin Tools -> Enhanced
# Backups, storage type "S3") using these credentials - no s3fs / FUSE mount
# required. Configure DA with:
#   - Endpoint/Region: us-east-1
#   - Bucket:          aws_s3_bucket.directadmin_backups.id (see output below)
#   - Access key:      created out-of-band for the IAM user below (see note)
#
# Goal: stop storing 390+ GB of weekly backups on the Main server's root EBS
# volume. Keep only a small local working set in DA; retain history in S3 where
# lifecycle rules tier it to cheaper storage and expire it automatically.

resource "aws_s3_bucket" "directadmin_backups" {
  bucket = "wbat-tellerstech-directadmin-backups-${data.aws_caller_identity.current.account_id}"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "tellerstech-directadmin-backups"
      "scm:file" = "aws/global/s3-directadmin-backups.tf"
    },
  )
}

resource "aws_s3_bucket_versioning" "directadmin_backups" {
  bucket = aws_s3_bucket.directadmin_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "directadmin_backups" {
  bucket = aws_s3_bucket.directadmin_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "directadmin_backups" {
  bucket = aws_s3_bucket.directadmin_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Retention / cost control. Recent backups stay instantly retrievable; older
# ones tier down and eventually expire. DirectAdmin's own retention still
# governs how many objects exist; this is the cost + cleanup backstop.
resource "aws_s3_bucket_lifecycle_configuration" "directadmin_backups" {
  bucket = aws_s3_bucket.directadmin_backups.id

  rule {
    id     = "tier-and-expire-backups"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR" # Glacier Instant Retrieval - no restore delay
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Dedicated IAM user for DirectAdmin, scoped to only this bucket.
resource "aws_iam_user" "directadmin_backup" {
  name          = "directadmin-backup"
  force_destroy = false

  tags = merge(
    var.core_tags,
    {
      "scm:file" = "aws/global/s3-directadmin-backups.tf"
    },
  )
}

resource "aws_iam_user_policy" "directadmin_backup" {
  name = "directadmin-backup-s3"
  user = aws_iam_user.directadmin_backup.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
        ]
        Resource = aws_s3_bucket.directadmin_backups.arn
      },
      {
        Sid    = "ReadWriteObjects"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.directadmin_backups.arn}/*"
      },
    ]
  })
}

# NOTE: The access key is intentionally NOT managed by Terraform (matches the
# pattern used for the TerraformCloud user, and keeps the secret out of state).
# Create it once and paste into DirectAdmin:
#
#   aws iam create-access-key --user-name directadmin-backup --profile wbat
#
# If you would rather have Terraform manage it, uncomment the block below and
# read the secret with: terraform output -raw directadmin_backup_secret_key
#
# resource "aws_iam_access_key" "directadmin_backup" {
#   user = aws_iam_user.directadmin_backup.name
# }
