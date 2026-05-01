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

resource "aws_security_group" "private" {
  name   = "${var.project_name}-private-sg"
  vpc_id = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_template" "nat" {
  name_prefix   = "${var.project_name}-nat-"
  image_id      = var.nat_ami_id
  instance_type = var.nat_instance_type

  iam_instance_profile {
    name = var.iam_instance_profile
  }

  network_interfaces {
    associate_public_ip_address = true
    # source_dest_check           = false
    security_groups = [aws_security_group.nat.id]
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
    apt install -y awscli iptables-persistent
    mkdir -p /tmp/ssm
    cd /tmp/ssm
    wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
    dpkg -i amazon-ssm-agent.deb || apt -f install -y
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-nat.conf
    sysctl --system

    TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
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

resource "aws_launch_template" "private" {
  name_prefix   = "${var.project_name}-private-"
  image_id      = var.private_ami_id
  instance_type = var.private_instance_type

  iam_instance_profile {
    name = var.iam_instance_profile
  }

  vpc_security_group_ids = [aws_security_group.private.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -eux
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true
    systemctl enable --now amazon-ssm-agent.service || true
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
    value               = "NAT-${substr(var.azs[count.index], length(var.azs[count.index]) - 2, 2)}"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_group" "private" {
  count = length(var.azs)

  name                = "${var.project_name}-private-asg-${var.azs[count.index]}"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 1
  vpc_zone_identifier = [var.private_subnet_ids[count.index]]

  launch_template {
    id      = aws_launch_template.private.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "Private-${substr(var.azs[count.index], length(var.azs[count.index]) - 2, 2)}"
    propagate_at_launch = true
  }
}

data "aws_instances" "nat_runtime" {
  count = length(var.azs)

  instance_state_names = ["running"]

  instance_tags = {
    Name = "NAT-${substr(var.azs[count.index], length(var.azs[count.index]) - 2, 2)}"
  }

  depends_on = [aws_autoscaling_group.nat]
}

data "aws_instance" "nat_runtime" {
  count = length(var.azs)

  instance_id = one(data.aws_instances.nat_runtime[count.index].ids)
}

resource "aws_route" "private_default_via_nat" {
  count = length(var.azs)

  route_table_id         = var.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = data.aws_instance.nat_runtime[count.index].network_interface_id
}
