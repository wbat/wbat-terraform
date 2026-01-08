# ACM Certificate for www.tellerstech.com
# DNS validation via BIND - keep the validation CNAME record permanently for auto-renewal

resource "aws_acm_certificate" "www_tellerstech" {
  domain_name       = "www.tellerstech.com"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(
    var.core_tags,
    {
      "scm:file" = "aws/global/acm/tellerstech.tf",
    },
  )
}
