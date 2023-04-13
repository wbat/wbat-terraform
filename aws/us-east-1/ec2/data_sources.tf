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
    values = ["Primary"]
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
    values = ["Secondary"]
  }
}
