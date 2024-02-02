# Providers
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

# Setup credentials and specify region
provider "aws" {
  region                   = "eu-north-1"
  shared_credentials_files = ["~/.aws/credentials"]
}

# Creating VPC
resource "aws_vpc" "main_vpc" {
  cidr_block = "10.1.0.0/16"
}

# Creating Subnet
resource "aws_subnet" "public_subnet1" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.1.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "eu-north-1a"
}

resource "aws_subnet" "public_subnet2" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.1.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "eu-north-1b"
}

# Creating IGW
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id
}
# Creating Route Table
resource "aws_route_table" "rtb" {
  vpc_id = aws_vpc.main_vpc.id
  route {
    gateway_id = aws_internet_gateway.igw.id
    cidr_block = "0.0.0.0/0"
  }
}

# Route Table Association

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_subnet1.id
  route_table_id = aws_route_table.rtb.id
}

# Creating Security Group
resource "aws_security_group" "main_sg" {
  vpc_id      = aws_vpc.main_vpc.id
  description = "main sg"
  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 80
    to_port     = 80
    protocol    = "TCP"
  }
  ingress {
    cidr_blocks = ["102.47.22.67/32"]
    from_port   = 22
    to_port     = 22
    protocol    = "TCP"
    description = "Allow SSH protocol into the machine"
  }
  egress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
  }
}

# Creating Bucket
resource "aws_s3_bucket" "bucket" {
  bucket = "moamen-zyan-bucket"
}

# Creating S3 Bucket
resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = aws_s3_bucket.bucket.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "PublicRead",
        Effect = "Allow",
        Principal = {
          AWS = aws_iam_role.EC2_role.arn,
        },
        Action   = ["s3:*"],
        Resource = [aws_s3_bucket.bucket.arn, "${aws_s3_bucket.bucket.arn}/*"],
      },
    ],
  })
}

# Creating IAM role
resource "aws_iam_role" "EC2_role" {
  name = "s3FullAccess"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Creating IAM Policy for S3
resource "aws_iam_policy" "S3FullAccess_policy" {
  name = "S3FullAccessPolicy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action   = "s3:*",
        Effect   = "Allow",
        Resource = "*",
      }
    ]
  })
}

# Creating IAM Policy for DynamoDB
resource "aws_iam_policy" "DynamoDB_Policy" {
  name = "DynamoDBFullAccess"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action   = "dynamodb:*",
        Effect   = "Allow",
        Resource = "*",
      }
    ]
  })
}

# Attaching Policy to role
resource "aws_iam_role_policy_attachment" "s3_role_policy_attachment" {
  policy_arn = aws_iam_policy.S3FullAccess_policy.arn
  role       = aws_iam_role.EC2_role.name
}

resource "aws_iam_role_policy_attachment" "db_role_policy_attachment" {
  policy_arn = aws_iam_policy.DynamoDB_Policy.arn
  role       = aws_iam_role.EC2_role.name
}

# Creating DynamoDB Table
resource "aws_dynamodb_table" "db_table" {
  name           = "Employees"
  hash_key       = "id"
  read_capacity  = 1
  write_capacity = 1

  attribute {
    name = "id"
    type = "S"
  }
}

# Creating Load Balancer
resource "aws_alb" "alb" {
  name               = "app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.main_sg.id]
  subnets            = [aws_subnet.public_subnet1.id, aws_subnet.public_subnet2.id]
}
# Creating Target Group
resource "aws_lb_target_group" "tg" {
  name     = "app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main_vpc.id
}

# Creating Load Balancer Listener
resource "aws_lb_listener" "lb" {
  load_balancer_arn = aws_alb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# Creating Auto Scaling Group
resource "aws_autoscaling_group" "asg" {
  name                      = "app_asg"
  max_size                  = 4
  min_size                  = 2
  desired_capacity          = 2
  health_check_grace_period = 300
  vpc_zone_identifier       = [aws_subnet.public_subnet1.id, aws_subnet.public_subnet2.id]
  default_cooldown          = 300
  launch_configuration      = aws_launch_configuration.launch_conf.id
  target_group_arns         = [aws_lb_target_group.tg.arn]
}

# Attaching ASG To Load Balancer Target Group
resource "aws_autoscaling_attachment" "asg_att" {
  autoscaling_group_name = aws_autoscaling_group.asg.id
  lb_target_group_arn    = aws_lb_target_group.tg.arn
}

# Creating ASG Policy
resource "aws_autoscaling_policy" "asg_policy" {
  name                   = "scale_up_policy"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 300
}

# Creating Cloud Watch Alarm For ASG Scaling Policy
resource "aws_cloudwatch_metric_alarm" "CPUAlarm" {
  alarm_name          = "CPU-Alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  period              = 120
  threshold           = 60
  namespace           = "AWS/EC2"
  statistic           = "Average"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
  alarm_actions = [aws_autoscaling_policy.asg_policy.arn]
}

# Creating Launch Configs
resource "aws_launch_configuration" "launch_conf" {
  name                 = "app_vm"
  image_id             = "ami-090793d48e56d862c"
  iam_instance_profile = aws_iam_instance_profile.instance_profile.name
  instance_type        = "t3.micro"
  security_groups      = [aws_security_group.main_sg.id]
  key_name             = "laptop"
  user_data            = <<-EOF
                #!/bin/bash
                cd /home/ec2-user
                wget https://aws-tc-largeobjects.s3-us-west-2.amazonaws.com/DEV-AWS-MO-GCNv2/FlaskApp.zip
                unzip FlaskApp.zip
                cd FlaskApp/
                yum install -y pip
                pip install -r requirements.txt
                export PHOTOS_BUCKET=${aws_s3_bucket.bucket.bucket}
                export AWS_DEFAULT_REGION=eu-north-1
                export DYNAMO_MODE=on
                FLASK_APP=application.py /usr/local/bin/flask run --host=0.0.0.0 --port=80 
  EOF
  depends_on           = [aws_s3_bucket.bucket, aws_iam_role_policy_attachment.s3_role_policy_attachment]
}

# Making Instance Profile
resource "aws_iam_instance_profile" "instance_profile" {
  name = "instanceProfileForEc2"
  role = aws_iam_role.EC2_role.name
}

# Output Of LB DNS Name
output "lb_public_ip" {
  value = aws_alb.alb.dns_name
}
