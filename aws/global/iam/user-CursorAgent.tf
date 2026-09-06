# AWS IAM user for Cursor Cloud Agents (read-only telemetry + Session Manager shell).
#
# Purpose: give an agent enough access to *see* the running system -- CloudWatch metrics
# and logs, EC2/CloudFront/SES/DLM describes, Cost Explorer, and a shell on the two
# instances -- without the ability to change any of it. Terraform changes still go
# through HCP Terraform and a reviewed PR; this credential deliberately cannot apply.
#
# Why a user and not a role: Cloud Agent secrets are static environment variables. There
# is no OIDC provider or instance identity in that VM to exchange for temporary
# credentials, so a long-lived key is the only mechanism available. That makes tight
# scoping the control that matters, which is what the policies below are for.

resource "aws_iam_user" "cursor_agent" {
  name = "cursor-agent"
  # Guard against a destroy quietly succeeding while access keys still exist; deleting
  # this user should be a deliberate act that starts with deleting the key.
  force_destroy = false

  tags = merge(
    var.core_tags,
    {
      "scm:file" = "aws/global/iam/user-CursorAgent.tf"
    },
  )
}

locals {
  # Shell access on the primary is root-equivalent: Session Manager lands as ssm-user,
  # which the SSM agent grants passwordless sudo, on the box serving ~91 WordPress
  # sites. That is the largest grant in this file and the one to revisit first. Setting
  # this to false removes the shell policy entirely and leaves telemetry intact --
  # nothing else here depends on it.
  cursor_agent_shell_access = true

  # Scoped by Name tag rather than instance ID on purpose. Instance IDs change (the
  # pre-shrink primary is already gone) and a stale hardcoded ID matches nothing, which
  # presents as a broken credential rather than as a deliberate restriction.
  cursor_agent_shell_targets = [
    "WBAT Primary Server",
    "WBAT Secondary Server",
  ]
}

# Always-on half: look, don't touch.
resource "aws_iam_user_policy" "cursor_agent_visibility" {
  name = "cursor-agent-visibility"
  user = aws_iam_user.cursor_agent.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Metrics and logs: the reason this credential exists. Includes Logs Insights
        # (StartQuery/GetQueryResults) because that is how anything useful gets found in
        # a log group of any size.
        Sid    = "ReadTelemetry"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:DescribeAlarmHistory",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:DescribeQueries",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:GetQueryResults",
          "logs:StartQuery",
          "logs:StopQuery",
        ]
        Resource = "*"
      },
      {
        # Describe-only view of the stack this repo manages, so an agent can compare
        # real infrastructure against the Terraform and spot drift. Read verbs only; no
        # Create/Modify/Delete/Put anywhere.
        Sid    = "DescribeInfrastructure"
        Effect = "Allow"
        Action = [
          "acm:Describe*",
          "acm:List*",
          "cloudfront:Get*",
          "cloudfront:List*",
          "dlm:Get*",
          "dlm:List*",
          "ec2:Describe*",
          "ec2:Get*",
          "iam:Get*",
          "iam:List*",
          "iam:GenerateServiceLastAccessedDetails",
          "kms:DescribeKey",
          "kms:ListAliases",
          "kms:ListKeys",
          "route53:Get*",
          "route53:List*",
          # Secret *metadata* only. GetSecretValue is absent here and explicitly denied
          # below.
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets",
          "ses:Describe*",
          "ses:Get*",
          "ses:List*",
          "sns:Get*",
          "sns:List*",
          "s3:GetBucketLocation",
          "s3:GetBucketPolicy",
          "s3:GetBucketVersioning",
          "s3:GetLifecycleConfiguration",
          "s3:ListAllMyBuckets",
          "s3:ListBucket",
          "wafv2:Get*",
          "wafv2:List*",
        ]
        Resource = "*"
      },
      {
        # Cost questions come up often enough in this repo (see
        # aws/docs/cost-optimization-checklist.md) that answering them should not
        # require a console login.
        Sid    = "ReadCost"
        Effect = "Allow"
        Action = [
          "ce:GetCostAndUsage",
          "ce:GetCostForecast",
          "ce:GetDimensionValues",
          "ce:GetTags",
          "budgets:Describe*",
          "budgets:View*",
        ]
        Resource = "*"
      },
      {
        # Hard ceiling. These stay denied even if someone later attaches a broad managed
        # policy such as ReadOnlyAccess, because an explicit Deny always wins in IAM
        # evaluation. The point is that this credential provably cannot read customer
        # data or secret material:
        #   - DirectAdmin backups in S3 contain every hosted site's files and databases.
        #   - GetSecretValue would expose the SES forwarding runtime config.
        #   - kms:Decrypt would route around both of the above.
        Sid    = "DenyDataAndSecretExfiltration"
        Effect = "Deny"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "secretsmanager:GetSecretValue",
          "kms:Decrypt",
        ]
        Resource = "*"
      },
    ]
  })
}

# Interactive half, kept in its own resource so the toggle above is a visible boundary
# rather than a conditional buried in a policy document.
resource "aws_iam_user_policy" "cursor_agent_shell" {
  count = local.cursor_agent_shell_access ? 1 : 0

  name = "cursor-agent-shell"
  user = aws_iam_user.cursor_agent.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Session Manager shell. No inbound port, no security-group change, no private
        # key to distribute, and every session is attributable in CloudTrail -- which is
        # why this is preferred over issuing an SSH key. The instance profile already
        # carries AmazonSSMManagedInstanceCore, so nothing changes on the instances.
        Sid      = "StartSessionOnManagedServers"
        Effect   = "Allow"
        Action   = ["ssm:StartSession"]
        Resource = "arn:aws:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringLike = {
            "ssm:resourceTag/Name" = local.cursor_agent_shell_targets
          }
        }
      },
      {
        # AWS-owned session documents, needed only when --document-name is passed:
        # ssh-over-SSM and port forwarding (useful for reaching DirectAdmin's admin port
        # without exposing it publicly). The default shell document needs no grant.
        Sid    = "UseSessionDocuments"
        Effect = "Allow"
        Action = ["ssm:StartSession"]
        Resource = [
          "arn:aws:ssm:us-east-1::document/AWS-StartSSHSession",
          "arn:aws:ssm:us-east-1::document/AWS-StartPortForwardingSession",
        ]
      },
      {
        # Own sessions only. Without the ${aws:username} scoping this could terminate
        # someone else's active session.
        Sid    = "ManageOwnSessions"
        Effect = "Allow"
        Action = [
          "ssm:TerminateSession",
          "ssm:ResumeSession",
        ]
        Resource = "arn:aws:ssm:*:*:session/$${aws:username}-*"
      },
      {
        # Needed to find the instances and confirm the SSM agent is actually online
        # before trying to connect.
        Sid    = "DescribeSsmFleet"
        Effect = "Allow"
        Action = [
          "ssm:DescribeInstanceInformation",
          "ssm:DescribeSessions",
          "ssm:GetConnectionStatus",
        ]
        Resource = "*"
      },
    ]
  })
}

# The access key is intentionally NOT managed by Terraform, matching the TerraformCloud
# and directadmin-backup users: an aws_iam_access_key resource writes the secret into
# HCP Terraform state in plaintext, and state is not where an agent credential belongs.
#
# Create it once, paste the two values into the Cursor dashboard under
# Cloud Agents > Secrets, and keep no local copy:
#
#   aws iam create-access-key --user-name cursor-agent --profile wbat
#
# To revoke agent access later, delete the key -- the user and policies can stay:
#
#   aws iam list-access-keys  --user-name cursor-agent --profile wbat
#   aws iam delete-access-key --user-name cursor-agent --access-key-id AKIA... --profile wbat
#
# See aws/docs/cloud-agent-access.md for the full setup, including the Tailscale and HCP
# Terraform halves.
