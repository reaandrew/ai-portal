# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AI Portal is a Terraform-based AWS infrastructure for deploying Open WebUI with AWS Bedrock integration, featuring Keycloak SSO (with Active Directory LDAP federation), PostgreSQL RDS, Langfuse observability, and Grafana metrics dashboards.

**Stack:** Terraform, AWS (EC2, RDS, ALB, Route53, ACM, Managed AD, Bedrock, Secrets Manager), Docker

## Common Commands

```bash
# Deploy infrastructure (uses aws-vault for credentials)
aws-vault exec ee-sso -- terraform init
aws-vault exec ee-sso -- terraform plan -var-file=ee.tfvars
aws-vault exec ee-sso -- terraform apply -var-file=ee.tfvars

# Destroy infrastructure
aws-vault exec ee-sso -- terraform destroy -var-file=ee.tfvars

# Retrieve tfvars from Secrets Manager
aws-vault exec ee-sso -- aws secretsmanager get-secret-value \
  --secret-id "ai-portal/ee-tfvars" \
  --query SecretString --output text > ee.tfvars

# Store tfvars in Secrets Manager (after changes)
aws-vault exec ee-sso -- aws secretsmanager put-secret-value \
  --secret-id "ai-portal/ee-tfvars" \
  --secret-string "$(cat ee.tfvars)"

# SSH into instances
ssh ec2-user@$(terraform output -raw open_webui_public_ip)
ssh ec2-user@$(terraform output -raw keycloak_public_ip)
ssh ec2-user@$(terraform output -raw bedrock_gateway_public_ip)
ssh ec2-user@$(terraform output -raw langfuse_public_ip)

# Check container logs
ssh ec2-user@<ip> "sudo docker logs open-webui"
ssh ec2-user@<ip> "sudo docker logs keycloak"
ssh ec2-user@<ip> "sudo docker logs pipelines"
ssh ec2-user@<ip> "sudo docker logs otel-collector"
```

## Architecture

```
Internet → ALB (TLS 1.3) → Host-based routing:
  - portal.openwebui.demos.apps.equal.expert  → Open WebUI (port 8080) + Pipelines (port 9099)
  - auth.openwebui.demos.apps.equal.expert    → Keycloak (port 8080)
  - langfuse.openwebui.demos.apps.equal.expert → Langfuse (port 3000)
  - grafana.openwebui.demos.apps.equal.expert  → Grafana (port 3000)

Open WebUI → Bedrock Gateway (port 8000) → AWS Bedrock API

Authentication: User → Open WebUI → Keycloak (OIDC) → AWS Managed AD (LDAP)

Observability:
  - Traces: Open WebUI → Langfuse SDK → Langfuse (ClickHouse)
  - Metrics: Systemd timer → InfluxDB → Grafana

Databases:
  - RDS PostgreSQL: 3 databases (aiportal, keycloak, langfuse)
  - ClickHouse: Langfuse trace storage
  - InfluxDB: Metrics time-series data
```

**5 EC2 Instances:**
- Open WebUI (t3.xlarge) - includes Pipelines + OTEL Collector
- Keycloak (t3.xlarge)
- Bedrock Gateway (t3.xlarge)
- Langfuse (t3.medium) - includes ClickHouse, Redis, MinIO
- Grafana (monitoring module) - includes InfluxDB

## Key Files

| File | Purpose |
|------|---------|
| `main.tf` | All infrastructure resources |
| `variables.tf` | Input variable definitions |
| `outputs.tf` | Output values (IPs, URLs, SSH commands) |
| `userdata_*.sh` | EC2 bootstrap scripts (embedded configs) |
| `ee.tfvars` | EE environment secrets (git-ignored, stored in Secrets Manager) |
| `monitoring/` | Separate Terraform module for Grafana + InfluxDB |

## Secrets Management

Terraform variables containing secrets are stored in AWS Secrets Manager:

| Secret | ARN |
|--------|-----|
| `ai-portal/ee-tfvars` | `arn:aws:secretsmanager:eu-west-2:889772146711:secret:ai-portal/ee-tfvars-vnGRhX` |

**Important:** After modifying `ee.tfvars`, update Secrets Manager:
```bash
aws-vault exec ee-sso -- aws secretsmanager put-secret-value \
  --secret-id "ai-portal/ee-tfvars" \
  --secret-string "$(cat ee.tfvars)"
```

## Pipeline Filters

Open WebUI has 5 pipeline filters that intercept all LLM requests:

| Filter | Purpose | Library |
|--------|---------|---------|
| Detoxify | Blocks toxic messages (ML model) | detoxify |
| LLM-Guard | Detects prompt injection attacks | llm-guard |
| PII Detection | Blocks personal identifiable information | llm-guard (Presidio) |
| Turn Limit | Limits conversation turns (default: 10) | - |
| Langfuse | Sends traces with token usage to Langfuse | langfuse>=3.0.0 |

**Critical Notes:**
- All filter pipelines MUST have `pipelines: List[str] = ["*"]` as the class default. Empty `[]` causes filters to never be invoked.
- Langfuse SDK v3 API: Use `gen.update(usage=...)` NOT `start_generation(..., usage=...)` - the latter raises TypeError.
- PII filter uses `llm-guard.Anonymize` which requires a `Vault()` object: `Anonymize(vault=Vault(), threshold=0.5)`

## Metrics Collection

Metrics are collected every 1 minute via systemd timer on the Open WebUI instance:

```
/opt/metrics/openwebui_metrics.sh → InfluxDB → Grafana
```

**Collected metrics:**
- `chat_usage` measurement with tags: `user`, `user_group`, `model`
- Fields: `prompt_tokens`, `completion_tokens`, `total_tokens`

**Configuration in ee.tfvars:**
```hcl
influxdb_url    = "http://<grafana-private-ip>:8086"
influxdb_token  = "<token>"
influxdb_org    = "aiportal"
influxdb_bucket = "openwebui"
```

## Important Configuration Notes

### Password Special Characters
- `db_password` and `keycloak_admin_password`: Avoid `!` (shell escaping issues in docker-compose)
- `ad_admin_password`: Can include `!` (properly escaped in LDAP JSON)

### Container Restarts
`docker-compose restart` does NOT reload .env files. Always use:
```bash
docker-compose down && docker-compose up -d
```

### WebSocket Support
Disabled (`ENABLE_WEBSOCKET_SUPPORT=false`) for ALB compatibility. Uses HTTP polling.

### Open WebUI OAuth
Users MUST have an email address set in Active Directory for OAuth login to work.

### Instance Restarts
EC2 userdata only runs on first boot. If metrics/services are missing after restart:
1. Check if systemd timers exist: `systemctl list-timers | grep metrics`
2. Re-run terraform apply to recreate the instance, OR
3. Manually create the systemd units from userdata_open_webui.sh

## Deployment Timeline

Full deployment takes 25-35 minutes:
- AWS Managed AD: 10-15 min (slowest)
- RDS PostgreSQL: 5-7 min
- EC2 instances + userdata: 5-7 min
- ALB + certificate: 2-3 min

## Debugging

```bash
# Check userdata script logs (EC2 bootstrap)
ssh ec2-user@<ip> "cat /var/log/cloud-init-output.log"

# Check container status
ssh ec2-user@<ip> "sudo docker ps -a"

# Check pipeline filter logs
ssh ec2-user@<ip> "sudo docker logs pipelines 2>&1 | tail -50"

# Check OTEL collector
ssh ec2-user@<ip> "sudo docker logs otel-collector 2>&1 | tail -20"

# Check metrics timer
ssh ec2-user@<ip> "sudo systemctl status openwebui-metrics.timer"
ssh ec2-user@<ip> "sudo journalctl -u openwebui-metrics.service --no-pager | tail -20"

# Test Bedrock Gateway health
curl http://<gateway-private-ip>:8000/health

# Check Langfuse traces (via ClickHouse)
ssh ec2-user@<langfuse-ip> "sudo docker exec -i langfuse-clickhouse clickhouse-client --query 'SELECT count(*) FROM traces'"

# Check InfluxDB metrics
ssh ec2-user@<grafana-ip> "sudo docker exec influxdb influx query 'from(bucket:\"openwebui\") |> range(start: -1h) |> count()' --org aiportal --token <token>"

# Test Keycloak health
curl https://auth.openwebui.demos.apps.equal.expert/health/ready

# Check OIDC discovery endpoint
curl https://auth.openwebui.demos.apps.equal.expert/realms/aiportal/.well-known/openid-configuration
```

## Terraform State

**Main infrastructure:**
- Bucket: `ai-portal-terraform-state-276447169330`
- Key: `ai-portal/terraform.tfstate`
- Region: `eu-west-2`

**Monitoring module:** Local state in `monitoring/terraform.tfstate`
