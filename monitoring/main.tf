# Grafana Monitoring Stack for OpenWebUI
# This is a SEPARATE deployment from the main infrastructure
# It reads from existing infrastructure via data sources only

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# =============================================================================
# DATA SOURCES - Read from existing infrastructure (NO MODIFICATIONS)
# =============================================================================

data "aws_vpc" "existing" {
  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-vpc"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-public-*"]
  }
}

data "aws_lb" "existing" {
  name = "${var.project_name}-alb"
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.aws_lb.existing.arn
  port              = 443
}

# ACM certificate is already attached to the ALB - no need to reference it

data "aws_route53_zone" "existing" {
  name = var.domain_name
}

data "aws_key_pair" "existing" {
  key_name = var.key_name
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# =============================================================================
# SECURITY GROUP - Grafana Instance
# =============================================================================

resource "aws_security_group" "grafana" {
  name        = "${var.project_name}-grafana-sg"
  description = "Security group for Grafana monitoring instance"
  vpc_id      = data.aws_vpc.existing.id

  # HTTP from ALB only
  ingress {
    description     = "HTTP from ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = tolist(data.aws_lb.existing.security_groups)
  }

  # SSH access (restrict in production)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # InfluxDB port for metrics ingestion from OpenWebUI
  ingress {
    description = "InfluxDB HTTP API"
    from_port   = 8086
    to_port     = 8086
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.existing.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-grafana-sg"
  }
}

# =============================================================================
# EC2 INSTANCE - Grafana + InfluxDB
# =============================================================================

resource "aws_instance" "grafana" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.grafana_instance_type
  key_name                    = data.aws_key_pair.existing.key_name
  vpc_security_group_ids      = [aws_security_group.grafana.id]
  subnet_id                   = data.aws_subnets.public.ids[0]
  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = base64encode(templatefile("${path.module}/userdata_grafana.sh", {
    influxdb_admin_user     = var.influxdb_admin_user
    influxdb_admin_password = var.influxdb_admin_password
    influxdb_org            = var.influxdb_org
    influxdb_bucket         = var.influxdb_bucket
    influxdb_token          = var.influxdb_token
    grafana_admin_user      = var.grafana_admin_user
    grafana_admin_password  = var.grafana_admin_password
    keycloak_url            = "https://${var.keycloak_subdomain}.${var.domain_name}"
    keycloak_realm          = var.keycloak_realm
    keycloak_client_id      = var.keycloak_grafana_client_id
    keycloak_client_secret  = var.keycloak_grafana_client_secret
    grafana_url             = "https://${var.grafana_subdomain}.${var.domain_name}"
    grafana_dashboard_id    = var.grafana_dashboard_id
  }))

  tags = {
    Name = "${var.project_name}-grafana"
  }
}

# =============================================================================
# ALB TARGET GROUP & LISTENER RULE
# =============================================================================

resource "aws_lb_target_group" "grafana" {
  name        = "${var.project_name}-grafana-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.existing.id
  target_type = "instance"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200,302"
    path                = "/api/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.project_name}-grafana-tg"
  }
}

resource "aws_lb_target_group_attachment" "grafana" {
  target_group_arn = aws_lb_target_group.grafana.arn
  target_id        = aws_instance.grafana.id
  port             = 3000
}

resource "aws_lb_listener_rule" "grafana" {
  listener_arn = data.aws_lb_listener.https.arn
  priority     = 30

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }

  condition {
    host_header {
      values = ["${var.grafana_subdomain}.${var.domain_name}"]
    }
  }
}

# =============================================================================
# ROUTE53 DNS RECORD
# =============================================================================

resource "aws_route53_record" "grafana" {
  zone_id = data.aws_route53_zone.existing.zone_id
  name    = "${var.grafana_subdomain}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = data.aws_lb.existing.dns_name
    zone_id                = data.aws_lb.existing.zone_id
    evaluate_target_health = true
  }
}
