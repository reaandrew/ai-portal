output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "open_webui_public_ip" {
  description = "Public IP address of Open WebUI instance"
  value       = aws_instance.open_webui.public_ip
}

output "open_webui_url" {
  description = "URL to access Open WebUI"
  value       = "http://${aws_instance.open_webui.public_ip}:8080"
}

output "bedrock_gateway_public_ip" {
  description = "Public IP address of Bedrock Gateway instance"
  value       = aws_instance.bedrock_gateway.public_ip
}

output "bedrock_gateway_private_ip" {
  description = "Private IP address of Bedrock Gateway instance"
  value       = aws_instance.bedrock_gateway.private_ip
}

output "bedrock_gateway_url" {
  description = "Internal URL for Bedrock Gateway"
  value       = "http://${aws_instance.bedrock_gateway.private_ip}:8000"
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = aws_db_instance.postgres.endpoint
}

output "rds_database_name" {
  description = "RDS database name"
  value       = aws_db_instance.postgres.db_name
}

output "active_directory_id" {
  description = "Active Directory ID"
  value       = aws_directory_service_directory.main.id
}

output "active_directory_dns_ips" {
  description = "Active Directory DNS IP addresses"
  value       = aws_directory_service_directory.main.dns_ip_addresses
}

output "active_directory_domain_name" {
  description = "Active Directory domain name"
  value       = aws_directory_service_directory.main.name
}

output "ssh_connection_open_webui" {
  description = "SSH command to connect to Open WebUI instance"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.open_webui.public_ip}"
}

output "ssh_connection_bedrock_gateway" {
  description = "SSH command to connect to Bedrock Gateway instance"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.bedrock_gateway.public_ip}"
}
output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.main.dns_name
}

output "ai_portal_url" {
  description = "HTTPS URL to access AI Portal"
  value       = "https://${var.subdomain}.${var.domain_name}"
}

output "certificate_arn" {
  description = "ACM Certificate ARN"
  value       = aws_acm_certificate.ai_portal.arn
}

output "keycloak_public_ip" {
  description = "Public IP address of Keycloak instance"
  value       = aws_instance.keycloak.public_ip
}

output "keycloak_url" {
  description = "HTTPS URL to access Keycloak"
  value       = "https://${var.keycloak_subdomain}.${var.domain_name}"
}

output "keycloak_admin_console" {
  description = "Keycloak Admin Console URL"
  value       = "https://${var.keycloak_subdomain}.${var.domain_name}/admin"
}

output "keycloak_oidc_discovery" {
  description = "OIDC Discovery URL for aiportal realm"
  value       = "https://${var.keycloak_subdomain}.${var.domain_name}/realms/aiportal/.well-known/openid-configuration"
}

output "ssh_connection_keycloak" {
  description = "SSH command to connect to Keycloak instance"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.keycloak.public_ip}"
}

