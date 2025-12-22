variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "ai-portal"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the application"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key content for EC2 access"
  type        = string
  sensitive   = true
}

variable "webui_instance_type" {
  description = "Instance type for Open WebUI EC2"
  type        = string
  default     = "t3.large"
}

variable "gateway_instance_type" {
  description = "Instance type for Bedrock Gateway EC2"
  type        = string
  default     = "t3.large"
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "aiportal"
}

variable "db_username" {
  description = "PostgreSQL master username"
  type        = string
  default     = "aiportaladmin"
  sensitive   = true
}

variable "db_password" {
  description = "PostgreSQL master password"
  type        = string
  sensitive   = true
}

variable "ad_domain_name" {
  description = "Active Directory domain name"
  type        = string
  default     = "corp.aiportal.local"
}

variable "ad_admin_password" {
  description = "Active Directory Admin password"
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "Root domain name (Route53 hosted zone)"
  type        = string
  default     = "forora.com"
}

variable "subdomain" {
  description = "Subdomain for AI Portal"
  type        = string
  default     = "ai"
}

variable "keycloak_subdomain" {
  description = "Subdomain for Keycloak"
  type        = string
  default     = "auth"
}

variable "keycloak_instance_type" {
  description = "Instance type for Keycloak EC2"
  type        = string
  default     = "t3.small"
}

variable "max_conversation_turns" {
  description = "Maximum conversation turns allowed for regular users"
  type        = number
  default     = 10
}

variable "langfuse_subdomain" {
  description = "Subdomain for Langfuse"
  type        = string
  default     = "langfuse"
}

variable "grafana_subdomain" {
  description = "Subdomain for Grafana"
  type        = string
  default     = "grafana"
}

variable "langfuse_instance_type" {
  description = "Instance type for Langfuse EC2"
  type        = string
  default     = "t3.medium"
}

variable "langfuse_public_key" {
  description = "Langfuse project public API key for Open WebUI integration"
  type        = string
  default     = "lf_pk_aiportal_openwebui"
}

variable "langfuse_secret_key" {
  description = "Langfuse project secret API key for Open WebUI integration"
  type        = string
  sensitive   = true
}

# Grafana Monitoring Integration (optional - set after monitoring stack is deployed)
variable "influxdb_url" {
  description = "InfluxDB URL for metrics collection (e.g., http://monitoring-ip:8086)"
  type        = string
  default     = ""
}

variable "influxdb_token" {
  description = "InfluxDB API token for metrics collection"
  type        = string
  default     = ""
}

variable "influxdb_org" {
  description = "InfluxDB organization name"
  type        = string
  default     = "aiportal"
}

variable "influxdb_bucket" {
  description = "InfluxDB bucket for OpenWebUI metrics"
  type        = string
  default     = "openwebui"
}
