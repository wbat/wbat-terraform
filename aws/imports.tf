######################################################
# Imports
# After successful import, comment out or remove these blocks
######################################################

# Legacy CDN (already imported, kept for reference)
# import {
#   to = module.global.module.cloudfront.aws_cloudfront_distribution.cdn_legacy[0]
#   id = "E1BJFU3JD7PL7F"
# }

# EC2 Instances - imported 2026-06-30 (primary cutover + EIPs); comment out after apply
# import {
#   to = module.us-east-1.module.ec2.aws_instance.primary
#   id = "i-0118b8ede80b52ef7"
# }
#
# import {
#   to = module.us-east-1.module.ec2.aws_eip.primary
#   id = "eipalloc-0e4834de5c1e13061"
# }
#
# import {
#   to = module.us-east-1.module.ec2.aws_eip_association.primary
#   id = "eipassoc-007018a225625abbb"
# }
#
# import {
#   to = module.us-east-1.module.ec2.aws_eip.secondary
#   id = "eipalloc-08734964d45fd5694"
# }
#
# import {
#   to = module.us-east-1.module.ec2.aws_eip_association.secondary
#   id = "eipassoc-0830bef1c1753210c"
# }

# Secondary EC2 instance - imported; commented out after successful apply.
# import {
#   to = module.us-east-1.module.ec2.aws_instance.secondary
#   id = "i-07e68eaf6cad1b838"
# }

# SNS Topic for SES Email Forwarding - imported; commented out after successful apply.
# import {
#   to = module.global.module.ses.aws_sns_topic.email_forwarding
#   id = "arn:aws:sns:us-east-1:708113892725:tellertech-email-forwarding"
# }

# SNS Topic Policy - imported; commented out after successful apply.
# import {
#   to = module.global.module.ses.aws_sns_topic_policy.email_forwarding
#   id = "arn:aws:sns:us-east-1:708113892725:tellertech-email-forwarding"
# }

# Site media archive bucket + IAM — imported 2026-09-08 (PR #136); comment out
# after successful apply. Created in AWS ahead of TF during the teller media split.
# import {
#   to = module.global.aws_s3_bucket.site_media_archive
#   id = "wbat-tellerstech-site-media-archive-708113892725"
# }
#
# import {
#   to = module.global.aws_s3_bucket_versioning.site_media_archive
#   id = "wbat-tellerstech-site-media-archive-708113892725"
# }
#
# import {
#   to = module.global.aws_s3_bucket_server_side_encryption_configuration.site_media_archive
#   id = "wbat-tellerstech-site-media-archive-708113892725"
# }
#
# import {
#   to = module.global.aws_s3_bucket_public_access_block.site_media_archive
#   id = "wbat-tellerstech-site-media-archive-708113892725"
# }
#
# import {
#   to = module.global.aws_s3_bucket_lifecycle_configuration.site_media_archive
#   id = "wbat-tellerstech-site-media-archive-708113892725"
# }
#
# import {
#   to = module.global.module.iam.aws_iam_role_policy.WBAT_Main_Server-SiteMediaArchive
#   id = "WBAT_Main_Server:SiteMediaArchive"
# }
