provider "aws" {
  region = var.region
}

data "terraform_remote_state" "network-configuration" {
  backend = "local"
  config {
    path="../infrastructure/terraform.tfstate"
  }
}

resource "aws_security_group" "ec2-public-security-group" {
  name = "EC2-Public-SG"
  description = "Internet reaching access for EC2 Instances"
  vpc_id = data.terraform_remote_state.network-configuration.vpc_id

  ingress {
    from_port = 80
    protocol = "TCP"
    to_port = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 22
    protocol = "TCP"
    to_port = 22
    cidr_blocks = ["103.151.184.2/32"] #Your current IP address
  }

  egress {
    from_port = 0
    protocol = "-1" #-1 means any protocol
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2-private-security-group" {
  name="EC2-Private-SG"
  description = "Only allow Public SG resources to access these instances"
  vpc_id = data.terraform_remote_state.network-configuration.vpc_id

  ingress {
    from_port = 0
    protocol = "-1"
    to_port = 0
    cidr_blocks = [aws_security_group.ec2-public-security-group.id]
  }

  ingress {
    from_port = 80
    protocol = "TCP"
    to_port = 80
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow health checking for instances using this SG"
  }

  egress {
    from_port = 0
    protocol = "-1"
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "elb-security-group" {
  name = "ELB-SG"
  description = "ELB Security Group"
  vpc_id = data.terraform_remote_state.network-configuration.vpc_id

  ingress {
    from_port = 0
    protocol = "-1"
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow web traffic to load balancer"
  }

  egress {
    from_port = 0
    protocol = "-1"
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "ec2-iam-role" {
  name="EC2-IAM-ROLE"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17"
  "Statement":
  [
    {
      "Effect": "Allow"
      "Principal": {
        "Service": ["ec2.amazonaws.com", "application-autoscaling.amazonaws.com"]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "ec2-iam-role-policy" {
  name = "EC2-IAM-Policy"
  role = aws_iam_role.ec2-iam-role.id
  policy = <<EOF
{
  "Version": "2012-10-17"
  "Statement":
  [
    {
      "Effect": "Allow"
      "Action":
      [
        "ec2:*",
        "elasticloadbalancing:*"
        "cloudwatch:*"
        "logs:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

#Instances that will be launched with this instance profile will have the above mentioned role and role policy.
resource "aws_iam_instance_profile" "ec2-instance-profile" {
  name = "EC2-IAM-Instance-Profile"
  role = aws_iam_role.ec2-iam-role.name
}

#Reading the latest ami from aws with data definition.
data "aws_ami" "launch-configuration-ami" {
  most_recent = true

  filter{
    name = "owner-alis"
    values = ["amazon"]
  }

  owners = ["amazon"]
}

#Creating Launch configuration for private EC2
resource "aws_launch_configuration" "ec2-private-launch-configuration" {
  image_id = data.aws_ami.launch-configuration-ami.id
  instance_type = var.ec2_instance_type
  key_name = var.key_pair_name
  associate_public_ip_address = false
  iam_instance_profile = aws_iam_instance_profile.ec2-instance-profile.name
  security_groups = [aws_security_group.ec2-private-security-group.id]

  user_data = file("production-backend-server-script.sh")
}

#Creating Launch Configuration for public EC2
resource "aws_launch_configuration" "ec2-public-launch-configuration" {
  image_id = data.aws_ami.launch-configuration-ami.id
  instance_type = var.ec2_instance_type
  key_name = var.key_pair_name
  associate_public_ip_address = true
  iam_instance_profile = aws_iam_instance_profile.ec2-instance-profile.name
  security_groups = [aws_security_group.ec2-public-security-group.id]
  user_data = file("production-server-script.sh")
}

#Creating Load Balancer for public instances
resource "aws_elb" "webapp-load-balancer" {
  name = "Production-WEBApp-LoadBalancer"
  internal = false #internet facing so kept false
  security_groups = [aws_security_group.elb-security-group.id]
  subnets = [
    data.terraform_remote_state.network-configuration.public_subnet_1_id,
    data.terraform_remote_state.network-configuration.public_subnet_2_id,
    data.terraform_remote_state.network-configuration.public_subnet_3_id,
  ]
  listener {
    instance_port = 80
    instance_protocol = "HTTP"
    lb_port = 80
    lb_protocol = "HTTP"
  }

  health_check {
    healthy_threshold = 5
    interval = 30
    target = "HTTP:80/index.html"
    timeout = 10
    unhealthy_threshold = 5
  }
}

#Creating Load Balancer for private instances
resource "aws_elb" "backend-load-balancer" {
  name = "Production-Backend-LoadBalancer"
  internal = true #to balance the load between the resources that are not exposed to internet.
  security_groups = [aws_security_group.elb-security-group.id]
  subnets = [
    data.terraform_remote_state.network-configuration.private_subnet_1_id,
    data.terraform_remote_state.network-configuration.private_subnet_2_id,
    data.terraform_remote_state.network-configuration.private_subnet_3_id,
  ]
  listener {
    instance_port = 80
    instance_protocol = "HTTP"
    lb_port = 80
    lb_protocol = "HTTP"
  }
  health_check {
    healthy_threshold = 5
    interval = 30
    target = "HTTP:80/index.html"
    timeout = 10
    unhealthy_threshold = 5
  }
}

#Creating an Auto Scaling Group for private EC2 Instances.
resource "aws_autoscaling_group" "ec2-private-auto-scaling-group" {
  name = "Production-Backend-AutoScalingGroup"
  vpc_zone_identifier = [
    data.terraform_remote_state.network-configuration.private_subnet_1_id,
    data.terraform_remote_state.network-configuration.private_subnet_2_id,
    data.terraform_remote_state.network-configuration.private_subnet_3_id
  ]
  max_size = var.max_instance_size
  min_size = var.min_instance_size
  launch_configuration = aws_launch_configuration.ec2-private-launch-configuration.name
  health_check_type = "ELB"
  load_balancers = [aws_elb.backend-load-balancer.name]
  tag {
    key = "Name"
    propagate_at_launch = false
    value = "Backend-EC2-Instance"
  }
  tag {
    key = "Type"
    propagate_at_launch = false
    value = "Backend"
  }
}

#Creating an Auto Scaling Group for public EC2 Instances.
resource "aws_autoscaling_group" "ec2-public-autoscaling-group" {
  name = "Production-WebApp-AutoScalingGroup"
  vpc_zone_identifier = [
    data.terraform_remote_state.network-configuration.public_subnet_1_id,
    data.terraform_remote_state.network-configuration.public_subnet_2_id,
    data.terraform_remote_state.network-configuration.public_subnet_3_id,
  ]
  max_size = var.max_instance_size
  min_size = var.min_instance_size
  launch_configuration = aws_launch_configuration.ec2-public-launch-configuration.name
  health_check_type = "ELB"
  load_balancers = [aws_elb.webapp-load-balancer.name]
  tag {
    key = "Name"
    propagate_at_launch = false
    value = "WebApp-EC2-Instance"
  }
  tag {
    key = "Type"
    propagate_at_launch = false
    value = "WebApp"
  }
}

