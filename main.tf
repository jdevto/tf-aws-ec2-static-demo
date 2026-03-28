resource "random_id" "suffix" {
  byte_length = 2
}

locals {
  subnet_count = var.use_alb ? var.az_count : 1
  # One EC2 per private subnet (per AZ) when ALB; single public instance otherwise.
  instance_count = var.use_alb ? var.az_count : 1
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_subnet" "public" {
  count = local.subnet_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count = local.subnet_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private subnets + NAT: only when ALB is used (EC2 sits here; ALB stays in public subnets).
resource "aws_subnet" "private" {
  count = var.use_alb ? var.az_count : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, 16 + count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
}

resource "aws_eip" "nat" {
  count  = var.use_alb ? 1 : 0
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  count = var.use_alb ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  count  = var.use_alb ? 1 : 0
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[0].id
  }
}

resource "aws_route_table_association" "private" {
  count = var.use_alb ? var.az_count : 0

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

resource "aws_security_group" "alb" {
  count = var.use_alb ? 1 : 0

  name_prefix = "alb-${random_id.suffix.hex}-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_http_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "instance" {
  name_prefix = "web-${random_id.suffix.hex}-"
  vpc_id      = aws_vpc.main.id

  dynamic "ingress" {
    for_each = var.use_alb ? [1] : []
    content {
      description     = "HTTP from ALB security group (forwarded client traffic)"
      from_port       = 80
      to_port         = 80
      protocol        = "tcp"
      security_groups = [aws_security_group.alb[0].id]
    }
  }

  # ALB health checks originate from load balancer nodes in the VPC. Referencing the
  # ALB security group is usually enough; allowing the VPC CIDR on :80 avoids rare
  # "Unhealthy: Health checks failed" when the SG chain does not match as expected.
  dynamic "ingress" {
    for_each = var.use_alb ? [1] : []
    content {
      description = "HTTP from VPC for ALB health checks and internal probes"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = [aws_vpc.main.cidr_block]
    }
  }

  dynamic "ingress" {
    for_each = var.use_alb ? [] : [1]
    content {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = [var.allowed_http_cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "web" {
  count = local.instance_count

  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = var.use_alb ? aws_subnet.private[count.index].id : aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.instance.id]
  user_data                   = templatefile("${path.module}/user_data.tftpl", { enable_ssm = var.enable_ssm })
  user_data_replace_on_change = true
  iam_instance_profile        = var.enable_ssm ? aws_iam_instance_profile.ssm[0].name : null

  metadata_options {
    http_tokens = "required"
  }

  # Static list only (Terraform requires this). When use_alb is false, NAT/private
  # resources have count 0; depends_on on them is still valid and adds no edges.
  depends_on = [
    aws_internet_gateway.main,
    aws_route_table_association.public,
    aws_route_table_association.private,
    aws_nat_gateway.main,
    aws_eip.nat,
  ]
}

resource "aws_lb" "main" {
  count = var.use_alb ? 1 : 0

  name_prefix        = "demo-"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "web" {
  count = var.use_alb ? 1 : 0

  name_prefix      = "web-"
  port             = 80
  protocol         = "HTTP"
  vpc_id           = aws_vpc.main.id
  protocol_version = "HTTP1"

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = "/"
    matcher             = "200"
    interval            = 15
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  count = var.use_alb ? 1 : 0

  load_balancer_arn = aws_lb.main[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web[0].arn
  }
}

resource "aws_lb_target_group_attachment" "web" {
  count = var.use_alb ? var.az_count : 0

  target_group_arn = aws_lb_target_group.web[0].arn
  target_id        = aws_instance.web[count.index].id
  port             = 80
}
