data "aws_ami" "nat" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = ["nat-instance-*"]
  }
}

data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"] # Debian's official AWS account

  filter {
    name   = "name"
    values = ["debian-${var.debian_version}-amd64-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "private_baked" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = ["private-instance-*"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-*-${var.ubuntu_version}-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

