resource "aws_security_group" "default" {
  name        = "default"
  description = "default VPC security group"
  vpc_id      = data.aws_vpc.main.id

  tags = merge(
    var.core_tags,
    {
      Name       = "Main",
      "scm:file" = "aws/us-east-1/sg/default.tf",
    },
  )
}
