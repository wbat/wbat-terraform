# S3 bucket for On Call Brief pipeline output (briefs/*.md).
# EC2 WBAT_Main_Server role has sync access via IAM policy in global/iam.
# Backup on server: scripts/backup_briefs.sh with BRIEFS_S3_URI=s3://<bucket_id>/

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "briefs" {
  bucket = "wbat-tellerstech-briefs-${data.aws_caller_identity.current.account_id}"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "tellerstech-oncallbrief-backups"
      "scm:file" = "aws/global/s3-briefs.tf"
    },
  )
}

resource "aws_s3_bucket_versioning" "briefs" {
  bucket = aws_s3_bucket.briefs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "briefs" {
  bucket = aws_s3_bucket.briefs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "briefs" {
  bucket = aws_s3_bucket.briefs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
