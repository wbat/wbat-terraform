data "aws_iam_role" "AWSDataLifecycleManagerDefaultRole" {
  name = "AWSDataLifecycleManagerDefaultRole"
}

data "aws_ebs_snapshot" "primary" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "volume-size"
    values = ["300"]
  }

  filter {
    name   = "tag:Name"
    values = ["WBAT Primary Server - First"]
  }
}

data "aws_ebs_snapshot" "secondary" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "volume-size"
    values = ["200"]
  }

  filter {
    name   = "tag:Name"
    values = ["WBAT Secondary Server - First"]
  }
}

data "aws_security_group" "default" {
  id = "sg-0e674f4e2937c6392"
}

data "aws_subnet" "selected" {
  id = "subnet-0cd389d67c7cee3af"
}
