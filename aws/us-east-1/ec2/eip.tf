# Elastic IPs for primary and secondary servers (pre-existing, imported)
resource "aws_eip" "primary" {
  domain = "vpc"

  tags = merge(
    var.core_tags,
    {
      Name       = "WBAT Primary Server"
      "scm:file" = "aws/us-east-1/ec2/eip.tf",
    },
  )
}

resource "aws_eip_association" "primary" {
  allocation_id = aws_eip.primary.id
  instance_id   = aws_instance.primary.id
}

resource "aws_eip" "secondary" {
  domain = "vpc"

  tags = merge(
    var.core_tags,
    {
      Name       = "WBAT Secondary Server"
      "scm:file" = "aws/us-east-1/ec2/eip.tf",
    },
  )
}

resource "aws_eip_association" "secondary" {
  allocation_id = aws_eip.secondary.id
  instance_id   = aws_instance.secondary.id
}
