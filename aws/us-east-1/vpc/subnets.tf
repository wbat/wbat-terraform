# Subnets for Main VPC
# All subnets auto-assign public IPv4 addresses

# us-east-1a - 172.30.0.0/24
# Import: terraform import module.us-east-1.module.vpc.aws_subnet.us_east_1a subnet-0cd389d67c7cee3af

resource "aws_subnet" "us_east_1a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "172.30.0.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = merge(
    var.core_tags,
    {
      Name       = "Main-us-east-1a"
      "scm:file" = "aws/us-east-1/vpc/subnets.tf"
    },
  )

  lifecycle {
    prevent_destroy = true
  }
}

# us-east-1c - 172.30.2.0/24
# Import: terraform import module.us-east-1.module.vpc.aws_subnet.us_east_1c subnet-049b4e87357d40fe5

resource "aws_subnet" "us_east_1c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "172.30.2.0/24"
  availability_zone       = "us-east-1c"
  map_public_ip_on_launch = true

  tags = merge(
    var.core_tags,
    {
      Name       = "Main-us-east-1c"
      "scm:file" = "aws/us-east-1/vpc/subnets.tf"
    },
  )

  lifecycle {
    prevent_destroy = true
  }
}

# us-east-1d - 172.30.3.0/24
# Import: terraform import module.us-east-1.module.vpc.aws_subnet.us_east_1d subnet-0a744e5bb2fd55c8c

resource "aws_subnet" "us_east_1d" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "172.30.3.0/24"
  availability_zone       = "us-east-1d"
  map_public_ip_on_launch = true

  tags = merge(
    var.core_tags,
    {
      Name       = "Main-us-east-1d"
      "scm:file" = "aws/us-east-1/vpc/subnets.tf"
    },
  )

  lifecycle {
    prevent_destroy = true
  }
}

# us-east-1e - 172.30.4.0/24
# Import: terraform import module.us-east-1.module.vpc.aws_subnet.us_east_1e subnet-043cee53adb856789

resource "aws_subnet" "us_east_1e" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "172.30.4.0/24"
  availability_zone       = "us-east-1e"
  map_public_ip_on_launch = true

  tags = merge(
    var.core_tags,
    {
      Name       = "Main-us-east-1e"
      "scm:file" = "aws/us-east-1/vpc/subnets.tf"
    },
  )

  lifecycle {
    prevent_destroy = true
  }
}
