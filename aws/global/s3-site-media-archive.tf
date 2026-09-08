# S3 bucket for large, static website media that is deliberately excluded from
# the nightly DirectAdmin account backups.
#
# Why this is a separate bucket rather than a prefix in the backup bucket.
# `aws/global/s3-directadmin-backups.tf` expires every object at 365 days, and
# that rule is written as `filter {}` precisely so nothing can escape it — the
# bucket's contract is "rotating backups, all of which eventually cost nothing".
# Content archived here is the *only* off-host copy of live site data, so it
# must never expire. Expressing that as a prefix carve-out would mean scoping
# the expiry rule to a list of backup prefixes, and the bucket's cost guarantee
# would then quietly depend on someone remembering to extend that list. Two
# buckets, each with one unambiguous retention contract, cannot fail that way.
#
# First use: `teller`, whose 54 GB does not fit the staging disk during a backup
# (see aws/docs/2026-09-06-primary-outage.md). About 34 GB of it is site media
# that has not changed in eight months to seven years, so copying it nightly was
# both what made the account unbackuppable and a waste of the transfer.
#
# Written by scripts/directadmin/sync_site_media.sh, which copies and verifies
# but never deletes.

resource "aws_s3_bucket" "site_media_archive" {
  bucket = "wbat-tellerstech-site-media-archive-${data.aws_caller_identity.current.account_id}"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "tellerstech-site-media-archive"
      "scm:file" = "aws/global/s3-site-media-archive.tf"
    },
  )
}

# Versioning is load-bearing here, not boilerplate. The source of truth for this
# content is the live website, so a deletion or a corrupting edit on the host
# would otherwise propagate here on the next run and leave no good copy.
resource "aws_s3_bucket_versioning" "site_media_archive" {
  bucket = aws_s3_bucket.site_media_archive.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site_media_archive" {
  bucket = aws_s3_bucket.site_media_archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "site_media_archive" {
  bucket = aws_s3_bucket.site_media_archive.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Tier down for cost, but never expire. Current versions are the live copy of
# data that exists nowhere else off-host; superseded versions are kept a year,
# which is the window in which anyone would notice a bad overwrite and want the
# previous file back.
resource "aws_s3_bucket_lifecycle_configuration" "site_media_archive" {
  bucket = aws_s3_bucket.site_media_archive.id

  rule {
    id     = "tier-down-never-expire"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR" # Instant Retrieval: restores without a thaw
    }

    # Deliberately no `expiration` block. See the header comment: adding one
    # here deletes the only off-host copy of live site content.

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
