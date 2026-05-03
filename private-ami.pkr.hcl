source "amazon-ebs" "private" {
  ami_name      = "private-instance-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
  instance_type = "t2.micro"
  region        = "us-west-2"
  profile       = "mrpocket2726"
  ssh_username  = "ubuntu"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-*-24.04-amd64-server-*"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }
}

build {
  sources = ["source.amazon-ebs.private"]

  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo snap refresh amazon-ssm-agent",
      "sudo snap start amazon-ssm-agent",
    ]
  }
}
