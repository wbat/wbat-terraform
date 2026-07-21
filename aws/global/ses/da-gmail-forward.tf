# DirectAdmin → SES Gmail forward (MX stays on DirectAdmin).
#
# Runtime config secret is always provisioned. Populate in AWS console / CLI;
# Terraform ignores secret_string changes after create. No addresses in git.

resource "aws_secretsmanager_secret" "da_gmail_forward" {
  name        = "tellerstech/ses-gmail-forward/runtime-config"
  description = "DA pipe forward config: recipients, gmail_destination, rate limits (no MX change)"

  tags = merge(
    var.core_tags,
    {
      "Name"     = "TellersTech DA SES Gmail Forward Config"
      "scm:file" = "aws/global/ses/da-gmail-forward.tf"
    },
  )
}

resource "aws_secretsmanager_secret_version" "da_gmail_forward" {
  secret_id = aws_secretsmanager_secret.da_gmail_forward.id

  secret_string = jsonencode({
    gmail_destination                 = ""
    recipients                        = []
    rate_limit_per_recipient_per_hour = 30
    rate_limit_global_per_hour        = 100
    max_message_bytes                 = 10485760
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
