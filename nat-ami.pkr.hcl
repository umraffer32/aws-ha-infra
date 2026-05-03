source "amazon-ebs" "nat" {                                                                                   
    ami_name      = "nat-instance-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
    instance_type = "t2.micro"                                                                                  
    region        = "us-west-2"
    profile       = "mrpocket2726"                                                                              
    ssh_username  = "admin"
                                                                                                            
    source_ami_filter {                                                                                         
      filters = {                                                                                               
        name                = "debian-13-amd64-*"                                                               
        virtualization-type = "hvm"
      }
      most_recent = true
      owners      = ["136693071363"]
    }                                                                                                           
  }
                                                                                                                
  build {         
    sources = ["source.amazon-ebs.nat"]
                                                                                                                
    provisioner "shell" {
      inline = [                                                                                                
        "sudo apt-get update",
        "sudo apt-get upgrade -y",
        "sudo apt-get install -y curl awscli iptables-persistent",
        "curl -O https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb",
        "sudo dpkg -i amazon-ssm-agent.deb",
        "sudo systemctl enable amazon-ssm-agent",
        "rm amazon-ssm-agent.deb",
      ]                                                                                                         
    }
  }
