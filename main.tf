terraform {
  backend "s3" {
    bucket         = "ai-portal-terraform-state-276447169330"
    key            = "ai-portal/terraform.tfstate"
    region         = "eu-west-2"
    encrypt        = true
#    dynamodb_table = "ai-portal-terraform-locks"
  }

  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "AI-Portal"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Data source for current AWS account
data "aws_caller_identity" "current" {}

# S3 bucket for provisioning scripts (to bypass 16KB userdata limit)
resource "aws_s3_bucket" "scripts" {
  bucket = "${var.project_name}-scripts-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.project_name}-scripts"
  }
}

resource "aws_s3_bucket_versioning" "scripts" {
  bucket = aws_s3_bucket.scripts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Full Open WebUI provisioning script stored in S3
resource "aws_s3_object" "open_webui_provision_script" {
  bucket = aws_s3_bucket.scripts.id
  key    = "provision_open_webui.sh"
  content = templatefile("${path.module}/userdata_open_webui.sh", {
    db_host                 = aws_db_instance.postgres.address
    db_name                 = var.db_name
    db_user                 = var.db_username
    db_password             = var.db_password
    bedrock_gateway         = aws_instance.bedrock_gateway.private_ip
    ad_dns_ips              = join(",", aws_directory_service_directory.main.dns_ip_addresses)
    ad_domain               = var.ad_domain_name
    ad_admin_password       = var.ad_admin_password
    ad_directory_id         = aws_directory_service_directory.main.id
    aws_region              = var.aws_region
    keycloak_url            = "https://${var.keycloak_subdomain}.${var.domain_name}"
    open_webui_url          = "https://${var.subdomain}.${var.domain_name}"
    max_conversation_turns  = var.max_conversation_turns
    keycloak_admin_password = var.ad_admin_password
    langfuse_url            = "https://${var.langfuse_subdomain}.${var.domain_name}"
    langfuse_public_key     = var.langfuse_public_key
    langfuse_secret_key     = var.langfuse_secret_key
    s3_bucket               = aws_s3_bucket.scripts.id
  })

  tags = {
    Name = "Open WebUI provisioning script"
  }
}

# AD users configuration stored in S3
resource "aws_s3_object" "ad_users_config" {
  bucket = aws_s3_bucket.scripts.id
  key    = "ad_users.yaml"
  source = "${path.module}/config/ad/users.yaml"
  etag   = filemd5("${path.module}/config/ad/users.yaml")

  tags = {
    Name = "AD users configuration"
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# Public Subnets (for EC2 instances)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet-${count.index + 1}"
  }
}

# Private Subnets (for RDS and AD)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-private-subnet-${count.index + 1}"
  }
}

# Route Table for Public Subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

# Route Table Associations for Public Subnets
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway for private subnets
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.project_name}-nat-gateway"
  }

  depends_on = [aws_internet_gateway.main]
}

# Route Table for Private Subnets
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

# Route Table Associations for Private Subnets
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Security Group for Open WebUI
resource "aws_security_group" "open_webui" {
  name        = "${var.project_name}-open-webui-sg"
  description = "Allow HTTP/HTTPS inbound and all outbound"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "Open WebUI default port"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-open-webui-sg"
  }
}

# Security Group for Bedrock Gateway
resource "aws_security_group" "bedrock_gateway" {
  name        = "${var.project_name}-bedrock-gateway-sg"
  description = "Allow HTTP/HTTPS inbound and all outbound"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "Gateway API port"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-bedrock-gateway-sg"
  }
}

# Security Group for RDS
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Allow PostgreSQL from VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from Open WebUI"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.open_webui.id]
  }

  ingress {
    description     = "PostgreSQL from Bedrock Gateway"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.bedrock_gateway.id]
  }

  ingress {
    description     = "PostgreSQL from Keycloak"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.keycloak.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

# Add Langfuse access to RDS (must be separate rule due to dependency order)
resource "aws_security_group_rule" "rds_from_langfuse" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.langfuse.id
  security_group_id        = aws_security_group.rds.id
  description              = "PostgreSQL from Langfuse"
}

# Security Group for Microsoft AD
resource "aws_security_group" "ad" {
  name        = "${var.project_name}-ad-sg"
  description = "Allow AD traffic from VPC"
  vpc_id      = aws_vpc.main.id

  # LDAP
  ingress {
    description = "LDAP"
    from_port   = 389
    to_port     = 389
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # LDAPS
  ingress {
    description = "LDAPS"
    from_port   = 636
    to_port     = 636
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Kerberos
  ingress {
    description = "Kerberos"
    from_port   = 88
    to_port     = 88
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "Kerberos UDP"
    from_port   = 88
    to_port     = 88
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  # DNS
  ingress {
    description = "DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "DNS UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ad-sg"
  }
}

# IAM Role for EC2 instances (Bedrock access)
resource "aws_iam_role" "bedrock_access" {
  name = "${var.project_name}-bedrock-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-bedrock-access-role"
  }
}

# IAM Policy for Bedrock access
resource "aws_iam_role_policy" "bedrock_access" {
  name = "${var.project_name}-bedrock-access-policy"
  role = aws_iam_role.bedrock_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:ListFoundationModels",
          "bedrock:GetFoundationModel"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ds:EnableDirectoryDataAccess",
          "ds:ResetUserPassword",
          "ds:AccessDSData",
          "ds-data:CreateUser",
          "ds-data:UpdateUser",
          "ds-data:DescribeUser"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.scripts.arn,
          "${aws_s3_bucket.scripts.arn}/*"
        ]
      }
    ]
  })
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "bedrock_access" {
  name = "${var.project_name}-bedrock-access-profile"
  role = aws_iam_role.bedrock_access.name
}

# AWS Managed Microsoft AD
resource "aws_directory_service_directory" "main" {
  name     = var.ad_domain_name
  password = var.ad_admin_password
  edition  = "Standard"
  type     = "MicrosoftAD"

  vpc_settings {
    vpc_id     = aws_vpc.main.id
    subnet_ids = aws_subnet.private[*].id
  }

  tags = {
    Name = "${var.project_name}-microsoft-ad"
  }
}

# RDS Subnet Group
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# RDS PostgreSQL Instance
resource "aws_db_instance" "postgres" {
  identifier             = "${var.project_name}-postgres"
  engine                 = "postgres"
  engine_version         = "15.15"
  instance_class         = var.rds_instance_class
  allocated_storage      = 20
  storage_type           = "gp3"
  storage_encrypted      = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "mon:04:00-mon:05:00"

  skip_final_snapshot       = var.environment == "dev" ? true : false
  final_snapshot_identifier = var.environment == "dev" ? null : "${var.project_name}-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"

  tags = {
    Name = "${var.project_name}-postgres"
  }
}

# SSH Key Pair
resource "aws_key_pair" "main" {
  key_name   = var.key_name
  public_key = var.ssh_public_key

  tags = {
    Name = "${var.project_name}-key-pair"
  }
}

# Latest Amazon Linux 2023 AMI
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

# EC2 Instance - Open WebUI
resource "aws_instance" "open_webui" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.webui_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.open_webui.id]
  iam_instance_profile   = aws_iam_instance_profile.bedrock_access.name
  key_name               = aws_key_pair.main.key_name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  # Minimal bootstrap that downloads and runs the full script from S3
  user_data = <<-EOF
#!/bin/bash
exec > >(tee -a /var/log/provisioning.log) 2>&1
echo "[BOOTSTRAP] Downloading provisioning script from S3..."
aws s3 cp s3://${aws_s3_bucket.scripts.id}/provision_open_webui.sh /tmp/provision.sh --region ${var.aws_region}
chmod +x /tmp/provision.sh
echo "[BOOTSTRAP] Executing provisioning script..."
/tmp/provision.sh
EOF

  tags = {
    Name = "${var.project_name}-open-webui"
  }

  depends_on = [aws_db_instance.postgres, aws_nat_gateway.main, aws_s3_object.open_webui_provision_script]
}

# EC2 Instance - Bedrock Access Gateway
resource "aws_instance" "bedrock_gateway" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.gateway_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.bedrock_gateway.id]
  iam_instance_profile   = aws_iam_instance_profile.bedrock_access.name
  key_name               = aws_key_pair.main.key_name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/userdata_bedrock_gateway.sh", {
    aws_region = var.aws_region
  })

  tags = {
    Name = "${var.project_name}-bedrock-gateway"
  }

  depends_on = [aws_nat_gateway.main]
}

# Security Group for Keycloak
resource "aws_security_group" "keycloak" {
  name        = "${var.project_name}-keycloak-sg"
  description = "Allow traffic to Keycloak"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from ALB"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-keycloak-sg"
  }
}

# EC2 Instance - Keycloak
resource "aws_instance" "keycloak" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.keycloak_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.keycloak.id]
  iam_instance_profile   = aws_iam_instance_profile.bedrock_access.name
  key_name               = aws_key_pair.main.key_name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/userdata_keycloak.sh", {
    aws_region              = var.aws_region
    db_endpoint             = split(":", aws_db_instance.postgres.endpoint)[0]
    db_port                 = aws_db_instance.postgres.port
    db_admin_database       = "postgres"
    db_name                 = "keycloak"
    db_username             = var.db_username
    db_password             = var.db_password
    db_sslmode              = "require"
    ad_server               = join(",", aws_directory_service_directory.main.dns_ip_addresses)
    ad_base_dn              = "OU=Users,OU=corp,DC=corp,DC=aiportal,DC=local"
    ad_bind_dn              = "Admin@corp.aiportal.local"
    ad_bind_password        = var.ad_admin_password
    keycloak_admin_user     = "admin"
    keycloak_admin_password = var.ad_admin_password
    keycloak_subdomain      = var.keycloak_subdomain
    domain_name             = var.domain_name
    openwebui_url           = "https://${var.subdomain}.${var.domain_name}"
    langfuse_url            = "https://${var.langfuse_subdomain}.${var.domain_name}"
  })

  tags = {
    Name = "${var.project_name}-keycloak"
  }

  depends_on = [aws_db_instance.postgres, aws_nat_gateway.main]
}

# Route53 Hosted Zone Data Source
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# ACM Certificate for subdomains (portal, auth, langfuse)
resource "aws_acm_certificate" "ai_portal" {
  domain_name       = "${var.subdomain}.${var.domain_name}"
  subject_alternative_names = [
    "${var.keycloak_subdomain}.${var.domain_name}",
    "${var.langfuse_subdomain}.${var.domain_name}"
  ]
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.project_name}-cert"
  }
}

# Route53 record for ACM validation
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.ai_portal.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main.zone_id
}

# Wait for certificate validation
resource "aws_acm_certificate_validation" "ai_portal" {
  certificate_arn         = aws_acm_certificate.ai_portal.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# Security Group for ALB
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTPS inbound to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "HTTP (redirect to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

# Update Open WebUI security group to allow ALB traffic
resource "aws_security_group_rule" "open_webui_from_alb" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.open_webui.id
  description              = "Allow ALB to Open WebUI"
}

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false
  enable_http2              = true
  drop_invalid_header_fields = true

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# Target Group for Open WebUI
resource "aws_lb_target_group" "open_webui" {
  name     = "${var.project_name}-webui-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  tags = {
    Name = "${var.project_name}-webui-tg"
  }
}

# Attach Open WebUI instance to target group
resource "aws_lb_target_group_attachment" "open_webui" {
  target_group_arn = aws_lb_target_group.open_webui.arn
  target_id        = aws_instance.open_webui.id
  port             = 8080
}

# Target Group for Keycloak
resource "aws_lb_target_group" "keycloak" {
  name     = "${var.project_name}-keycloak-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/health/ready"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 3
  }

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  tags = {
    Name = "${var.project_name}-keycloak-tg"
  }
}

# Attach Keycloak instance to target group
resource "aws_lb_target_group_attachment" "keycloak" {
  target_group_arn = aws_lb_target_group.keycloak.arn
  target_id        = aws_instance.keycloak.id
  port             = 8080
}

# HTTPS Listener with TLS 1.3
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.ai_portal.certificate_arn

  # Default action - return 404
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

# Listener Rule for Open WebUI (ai.forora.com)
resource "aws_lb_listener_rule" "open_webui" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.open_webui.arn
  }

  condition {
    host_header {
      values = ["${var.subdomain}.${var.domain_name}"]
    }
  }
}

# Listener Rule for Keycloak (auth.forora.com)
resource "aws_lb_listener_rule" "keycloak" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 101

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }

  condition {
    host_header {
      values = ["${var.keycloak_subdomain}.${var.domain_name}"]
    }
  }
}

# HTTP Listener (redirect to HTTPS)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Route53 A record for subdomain (e.g., ai.forora.com)
resource "aws_route53_record" "ai_portal" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${var.subdomain}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# Route53 A record for Keycloak subdomain (auth.forora.com)
resource "aws_route53_record" "keycloak" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${var.keycloak_subdomain}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# ==========================================
# LANGFUSE - LLM Observability Platform
# ==========================================

# Security Group for Langfuse
resource "aws_security_group" "langfuse" {
  name        = "${var.project_name}-langfuse-sg"
  description = "Allow traffic to Langfuse"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # Allow Open WebUI to send traces to Langfuse
  ingress {
    description     = "Langfuse API from Open WebUI"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.open_webui.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-langfuse-sg"
  }
}

# EC2 Instance - Langfuse
resource "aws_instance" "langfuse" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.langfuse_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.langfuse.id]
  iam_instance_profile   = aws_iam_instance_profile.bedrock_access.name
  key_name               = aws_key_pair.main.key_name

  root_block_device {
    volume_size = 60  # Increased from 30GB to handle ClickHouse data growth
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/userdata_langfuse.sh", {
    db_endpoint                = split(":", aws_db_instance.postgres.endpoint)[0]
    db_port                    = aws_db_instance.postgres.port
    db_admin_database          = "postgres"
    db_name                    = "langfuse"
    db_username                = var.db_username
    db_password                = var.db_password
    langfuse_url               = "https://${var.langfuse_subdomain}.${var.domain_name}"
    keycloak_url               = "https://${var.keycloak_subdomain}.${var.domain_name}"
    langfuse_public_key        = var.langfuse_public_key
    langfuse_secret_key        = var.langfuse_secret_key
    langfuse_init_user_password = var.ad_admin_password
  })

  tags = {
    Name = "${var.project_name}-langfuse"
  }

  depends_on = [aws_db_instance.postgres, aws_nat_gateway.main]
}

# Target Group for Langfuse
resource "aws_lb_target_group" "langfuse" {
  name     = "${var.project_name}-langfuse-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/api/public/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 3
  }

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  tags = {
    Name = "${var.project_name}-langfuse-tg"
  }
}

# Attach Langfuse instance to target group
resource "aws_lb_target_group_attachment" "langfuse" {
  target_group_arn = aws_lb_target_group.langfuse.arn
  target_id        = aws_instance.langfuse.id
  port             = 3000
}

# Listener Rule for Langfuse
resource "aws_lb_listener_rule" "langfuse" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 102

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.langfuse.arn
  }

  condition {
    host_header {
      values = ["${var.langfuse_subdomain}.${var.domain_name}"]
    }
  }
}

# Route53 A record for Langfuse subdomain
resource "aws_route53_record" "langfuse" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${var.langfuse_subdomain}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

