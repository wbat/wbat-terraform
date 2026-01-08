output "vpc_id" {
  value       = aws_vpc.main.id
  description = "ID of the Main VPC"
}

output "vpc_cidr_block" {
  value       = aws_vpc.main.cidr_block
  description = "CIDR block of the Main VPC"
}

output "internet_gateway_id" {
  value       = aws_internet_gateway.main.id
  description = "ID of the Internet Gateway"
}

output "subnet_ids" {
  value = {
    us_east_1a = aws_subnet.us_east_1a.id
    us_east_1c = aws_subnet.us_east_1c.id
    us_east_1d = aws_subnet.us_east_1d.id
    us_east_1e = aws_subnet.us_east_1e.id
  }
  description = "Map of subnet IDs by availability zone"
}

output "subnet_id_list" {
  value = [
    aws_subnet.us_east_1a.id,
    aws_subnet.us_east_1c.id,
    aws_subnet.us_east_1d.id,
    aws_subnet.us_east_1e.id,
  ]
  description = "List of all subnet IDs"
}
