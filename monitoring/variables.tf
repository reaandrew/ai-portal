# Variables for Grafana Monitoring Stack

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Project name (must match existing infrastructure)"
  type        = string
  default     = "ai-portal"
}

variable "domain_name" {
  description = "Domain name (must match existing infrastructure)"
  type        = string
}

variable "grafana_subdomain" {
  description = "Subdomain for Grafana"
  type        = string
  default     = "grafana.openwebui"
}

variable "keycloak_subdomain" {
  description = "Keycloak subdomain (must match existing infrastructure)"
  type        = string
}

variable "key_name" {
  description = "SSH key name (must match existing infrastructure)"
  type        = string
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "grafana_instance_type" {
  description = "EC2 instance type for Grafana"
  type        = string
  default     = "t3.small"
}

# InfluxDB Configuration
variable "influxdb_admin_user" {
  description = "InfluxDB admin username"
  type        = string
  default     = "admin"
}

variable "influxdb_admin_password" {
  description = "InfluxDB admin password"
  type        = string
  sensitive   = true
}

variable "influxdb_org" {
  description = "InfluxDB organization name"
  type        = string
  default     = "aiportal"
}

variable "influxdb_bucket" {
  description = "InfluxDB bucket name"
  type        = string
  default     = "telegraf"
}

variable "influxdb_token" {
  description = "InfluxDB API token for data access"
  type        = string
  sensitive   = true
}

# Grafana Configuration
variable "grafana_admin_user" {
  description = "Grafana admin username"
  type        = string
  default     = "admin"
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}

variable "grafana_dashboard_id" {
  description = "Grafana dashboard ID to import"
  type        = string
  default     = "22867"
}

# Keycloak Integration
variable "keycloak_realm" {
  description = "Keycloak realm name"
  type        = string
  default     = "aiportal"
}

variable "keycloak_grafana_client_id" {
  description = "Keycloak client ID for Grafana"
  type        = string
  default     = "grafana"
}

variable "keycloak_grafana_client_secret" {
  description = "Keycloak client secret for Grafana"
  type        = string
  sensitive   = true
}
