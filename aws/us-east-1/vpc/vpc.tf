# Main VPC - CIDR 172.30.0.0/16
# Import: terraform import module.us-east-1.module.vpc.aws_vpc.main vpc-0b308c063a4e4f0e8

resource "aws_vpc" "main" {
  cidr_block           = "172.30.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(
    var.core_tags,
    {
      Name       = "Main"
      "scm:file" = "aws/us-east-1/vpc/vpc.tf"
    },
  )

  lifecycle {
    prevent_destroy = true
  }
}

# Internet Gateway
# Import: terraform import module.us-east-1.module.vpc.aws_internet_gateway.main igw-035487cce1b50a6bc

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(
    var.core_tags,
    {
      Name       = "Main"
      "scm:file" = "aws/us-east-1/vpc/vpc.tf"
    },
  )

  lifecycle {
    prevent_destroy = true
  }
}

# Main Route Table
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(
    var.core_tags,
    {
      Name       = "Main"
      "scm:file" = "aws/us-east-1/vpc/vpc.tf"
    },
  )

  lifecycle {
    prevent_destroy = true
  }
}
