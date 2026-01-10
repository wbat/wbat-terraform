# AWS Compute Savings Plan
# Provides ~30% discount on EC2, Lambda, and Fargate compute
#
# IMPORTANT: Savings Plans are a financial commitment and CANNOT be cancelled.
# Review carefully before applying.

resource "aws_savingsplans_plan" "compute" {
  count = var.enable_savings_plan ? 1 : 0

  savings_plan_type = "Compute" # Most flexible - works across instance types/regions
  payment_option    = "No Upfront"
  term              = "One-Year" # Options: "One-Year" or "Three-Year"

  # Hourly commitment in USD
  # t3a.medium on-demand: $0.0376/hr
  # With Compute Savings Plan: ~$0.026/hr (30% off)
  # Set commitment to cover 24/7 usage: $0.026/hr
  commitment = var.savings_plan_hourly_commitment

  tags = merge(
    var.core_tags,
    {
      "Name"     = "Compute Savings Plan"
      "scm:file" = "aws/global/savings-plans.tf"
    },
  )
}
