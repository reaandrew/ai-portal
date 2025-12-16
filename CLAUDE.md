# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AI Portal is a Terraform-based AWS infrastructure for deploying Open WebUI with AWS Bedrock integration, featuring Keycloak SSO (with Active Directory LDAP federation), PostgreSQL RDS, and Langfuse observability.

**Stack:** Terraform, AWS (EC2, RDS, ALB, Route53, ACM, Managed AD, Bedrock), Docker

## Common Commands

```bash
# Deploy infrastructure (uses aws-vault for credentials)
aws-vault exec <profile> -- terraform init
aws-vault exec <profile> -- terraform plan -var-file=<profile>.tfvars
aws-vault exec <profile> -- terraform apply -var-file=<profile>.tfvars

# Destroy infrastructure
aws-vault exec <profile> -- terraform destroy -var-file=<profile>.tfvars

# Sync Bedrock models to Open WebUI database
./sync_models.sh

# SSH into instances
ssh ec2-user@$(terraform output -raw open_webui_public_ip)
ssh ec2-user@$(terraform output -raw keycloak_public_ip)
ssh ec2-user@$(terraform output -raw bedrock_gateway_public_ip)
ssh ec2-user@$(terraform output -raw langfuse_public_ip)

# Check container logs
ssh ec2-user@<ip> "sudo docker logs open-webui"
ssh ec2-user@<ip> "sudo docker logs keycloak"
ssh ec2-user@<ip> "sudo docker logs pipelines"
```

## Architecture

```
Internet → ALB (TLS 1.3) → Host-based routing:
  - ai.forora.com      → Open WebUI (port 8080) + Pipelines (port 9099)
  - auth.forora.com    → Keycloak (port 8080)
  - langfuse.forora.com → Langfuse (port 3000)

Open WebUI → Bedrock Gateway (port 8000) → AWS Bedrock API

Authentication: User → Open WebUI → Keycloak (OIDC) → AWS Managed AD (LDAP)

Databases: Shared RDS PostgreSQL with 3 databases (aiportal, keycloak, langfuse)
```

**4 EC2 Instances:** Open WebUI (t3.large), Keycloak (t3.small), Bedrock Gateway (t3.large), Langfuse (t3.medium)

## Key Files

| File | Purpose |
|------|---------|
| `main.tf` | All infrastructure resources |
| `variables.tf` | Input variable definitions |
| `outputs.tf` | Output values (IPs, URLs, SSH commands) |
| `userdata_*.sh` | EC2 bootstrap scripts (embedded configs) |
| `sync_models.sh` | Sync Bedrock models to Open WebUI DB |
| `<profile>.tfvars` | Secrets per environment (git-ignored) |

## Pipeline Filters

Open WebUI has 4 pipeline filters that intercept all LLM requests:

| Filter | Purpose |
|--------|---------|
| Detoxify | Blocks toxic messages (ML model) |
| LLM-Guard | Detects prompt injection attacks |
| Turn Limit | Limits conversation turns (default: 10) |
| Langfuse | Sends traces with token usage to Langfuse |

**Critical:** All filter pipelines MUST have `pipelines: List[str] = ["*"]` as the class default. Empty `[]` causes filters to never be invoked.

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

# Test Bedrock Gateway health
curl http://<gateway-private-ip>:8000/health
curl http://<gateway-private-ip>:8000/api/tags | jq '.models | length'

# Test Keycloak health
curl https://auth.forora.com/health/ready

# Check OIDC discovery endpoint
curl https://auth.forora.com/realms/aiportal/.well-known/openid-configuration
```

## Terraform Backend

State stored in S3 with versioning:
- Bucket: `ai-portal-terraform-state-276447169330`
- Key: `ai-portal/terraform.tfstate`
- Region: `eu-west-2`
