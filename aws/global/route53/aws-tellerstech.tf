# Route53 resources for aws.tellerstech.com zone

# Reference existing hosted zone (already in AWS, delegated via NS records in BIND)
data "aws_route53_zone" "aws_tellerstech" {
  name = "aws.tellerstech.com"
}

# Origin record - CloudFront uses this to reach EC2
resource "aws_route53_record" "origin" {
  zone_id = data.aws_route53_zone.aws_tellerstech.zone_id
  name    = "origin.aws.tellerstech.com"
  type    = "A"
  ttl     = 300
  records = [var.ec2_elastic_ip]

  lifecycle {
    prevent_destroy = true
  }
}
