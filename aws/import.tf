# Import blocks for existing VPC infrastructure
# Run `terraform plan` to import these resources, then remove this file

import {
  to = module.us-east-1.module.vpc.aws_vpc.main
  id = "vpc-0b308c063a4e4f0e8"
}

import {
  to = module.us-east-1.module.vpc.aws_internet_gateway.main
  id = "igw-035487cce1b50a6bc"
}

import {
  to = module.us-east-1.module.vpc.aws_route_table.main
  id = "rtb-0b39aeef254641ad4"
}

import {
  to = module.us-east-1.module.vpc.aws_subnet.us_east_1a
  id = "subnet-0cd389d67c7cee3af"
}

import {
  to = module.us-east-1.module.vpc.aws_subnet.us_east_1c
  id = "subnet-049b4e87357d40fe5"
}

import {
  to = module.us-east-1.module.vpc.aws_subnet.us_east_1d
  id = "subnet-0a744e5bb2fd55c8c"
}

import {
  to = module.us-east-1.module.vpc.aws_subnet.us_east_1e
  id = "subnet-043cee53adb856789"
}
