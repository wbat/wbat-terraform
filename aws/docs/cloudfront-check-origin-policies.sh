#!/bin/bash
# Confirm which origin request policy each cache behavior uses.
# Run with valid AWS credentials. Pass distribution ID or we'll try to find it.
#
# Usage: ./cloudfront-check-origin-policies.sh [DISTRIBUTION_ID]
#
# One-liner without this script (replace DIST_ID):
#   aws cloudfront get-distribution-config --id DIST_ID --query 'DistributionConfig.{Default:DefaultCacheBehavior.OriginRequestPolicyId,Behaviors:CacheBehaviors.Items[*].{Path:PathPattern,Policy:OriginRequestPolicyId}}' --output json

set -e
DIST_ID="${1:-}"

if [ -z "$DIST_ID" ]; then
  echo "Finding distribution for www.tellerstech.com..."
  DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?contains(Aliases.Items, 'www.tellerstech.com')].Id | [0]" --output text)
  if [ -z "$DIST_ID" ] || [ "$DIST_ID" = "None" ]; then
    echo "Could not find distribution. Pass ID: $0 E1234ABCD5678"
    exit 1
  fi
  echo "Distribution ID: $DIST_ID"
fi

# Get ETag for the config (required for get-distribution-config)
ETAG=$(aws cloudfront get-distribution-config --id "$DIST_ID" --query 'ETag' --output text)
# Get config JSON
aws cloudfront get-distribution-config --id "$DIST_ID" --query 'DistributionConfig' > /tmp/cf-config.json

echo ""
echo "Cache behaviors: path pattern -> origin_request_policy_id"
echo "--------------------------------------------------------"

# Default behavior
DEF_POLICY=$(jq -r '.DefaultCacheBehavior.OriginRequestPolicyId // "n/a"' /tmp/cf-config.json)
echo "DEFAULT (catch-all): $DEF_POLICY"

# Ordered behaviors
jq -r '.CacheBehaviors.Items[] | "\(.PathPattern): \(.OriginRequestPolicyId)"' /tmp/cf-config.json

echo ""
echo "AWS Managed policy IDs (for reference):"
echo "  AllViewer (does NOT reliably forward Host for custom origins): 216adef6-5c7f-47e4-b989-5492eafa07d3"
echo "  Our WordPress policy (forwards Host):                           <custom id from Terraform>"
echo ""
echo "If /wp-login.php and /wp-admin/* show 216adef6-..., they were NOT using the Host-forwarding policy."
rm -f /tmp/cf-config.json
