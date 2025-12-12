# Outputs for Grafana Monitoring Stack

output "grafana_url" {
  description = "Grafana URL"
  value       = "https://${var.grafana_subdomain}.${var.domain_name}"
}

output "grafana_instance_id" {
  description = "Grafana EC2 instance ID"
  value       = aws_instance.grafana.id
}

output "grafana_public_ip" {
  description = "Grafana EC2 public IP"
  value       = aws_instance.grafana.public_ip
}

output "influxdb_url" {
  description = "InfluxDB URL (internal VPC access)"
  value       = "http://${aws_instance.grafana.private_ip}:8086"
}

output "influxdb_write_url" {
  description = "InfluxDB write endpoint for OpenWebUI metrics"
  value       = "http://${aws_instance.grafana.private_ip}:8086/api/v2/write?org=${var.influxdb_org}&bucket=${var.influxdb_bucket}"
}

output "keycloak_client_setup" {
  description = "Instructions for Keycloak client setup"
  value       = <<-EOT
    Create a new client in Keycloak (${var.keycloak_subdomain}.${var.domain_name}):
    - Client ID: ${var.keycloak_grafana_client_id}
    - Client Protocol: openid-connect
    - Access Type: confidential
    - Valid Redirect URIs: https://${var.grafana_subdomain}.${var.domain_name}/login/generic_oauth
    - Web Origins: https://${var.grafana_subdomain}.${var.domain_name}
  EOT
}
