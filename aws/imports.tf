######################################################
# Imports
# After successful import, comment out or remove these blocks
######################################################

# Legacy CDN (already imported, kept for reference)
# import {
#   to = module.global.module.cloudfront.aws_cloudfront_distribution.cdn_legacy[0]
#   id = "E1BJFU3JD7PL7F"
# }

# EC2 Instances - importing existing "pet" servers into Terraform management
import {
  to = module.us-east-1.module.ec2.aws_instance.primary
  id = "i-0572702f0a58f6dcd"
}

import {
  to = module.us-east-1.module.ec2.aws_instance.secondary
  id = "i-07e68eaf6cad1b838"
}
