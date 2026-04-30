resource "aws_security_group" "nat" {
  name   = "${var.project_name}-nat-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_template" "nat" {
  name_prefix   = "${var.project_name}-nat-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    name = var.iam_instance_profile
  }

  network_interfaces {
    associate_public_ip_address = true
    # source_dest_check           = false
    security_groups             = [aws_security_group.nat.id]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -eux
    export DEBIAN_FRONTEND=noninteractive
    sleep 10
    IFACE=$(ip route | awk '/default/ {print $5; exit}')
    apt update
    mkdir -p /tmp/ssm
    cd /tmp/ssm
    wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
    dpkg -i amazon-ssm-agent.deb || apt -f install -y
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
    apt install -y iptables-persistent
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-nat.conf
    sysctl --system

    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
    aws ec2 modify-instance-attribute \
      --instance-id $INSTANCE_ID \
      --no-source-dest-check \
      --region $REGION

    iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -j ACCEPT
    netfilter-persistent save
    systemctl enable netfilter-persistent
  EOF
  )
}

resource "aws_autoscaling_group" "nat" {
  count = length(var.azs)

  name                = "${var.project_name}-nat-asg-${var.azs[count.index]}"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 1
  vpc_zone_identifier = [var.public_subnet_ids[count.index]]

  launch_template {
    id      = aws_launch_template.nat.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value = "NAT-${substr(var.azs[count.index], length(var.azs[count.index]) - 2, 2)}"
    propagate_at_launch = true
  }
}
