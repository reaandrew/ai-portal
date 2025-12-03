# AI Portal Credentials - Equal Expert Deployment

## Open WebUI Portal

**URL:** https://portal.openwebui.demos.apps.equal.expert

### Admin User (Admin Role)
- **Username:** Admin
- **Password:** YourSecureADPassword123
- **Email:** admin@corp.aiportal.local

### Test User (Regular User)
- **Username:** testuser
- **Password:** Welcome@2024
- **Email:** testuser@corp.aiportal.local

---

## Keycloak Admin Console

**URL:** https://auth.openwebui.demos.apps.equal.expert/admin

### Admin Login
- **Username:** admin
- **Password:** YourSecureADPassword123
- **Realm:** master (default) or switch to `aiportal` realm

---

## Langfuse (LLM Observability)

**URL:** https://langfuse.openwebui.demos.apps.equal.expert

### Authentication
- Login via **Keycloak SSO** (same AD credentials as Open WebUI)
- Admin user and testuser can both access

### Auto-Provisioned Configuration
The following are automatically created during deployment:
- **Organization:** AI Portal
- **Project:** Open WebUI
- **API Keys:** Pre-configured in Open WebUI pipelines

### API Keys (for reference)
- **Public Key:** `lf_pk_aiportal_openwebui`
- **Secret Key:** `lf_sk_aiportal_openwebui_secret`

No manual setup required - traces appear automatically when using Open WebUI.

---

## Pipelines (Safety Filters)

Configured in Open WebUI Admin Panel → Settings → Pipelines

| Filter | Purpose | Threshold |
|--------|---------|-----------|
| **Detoxify** | Blocks toxic/harmful messages | toxicity > 0.5 |
| **LLM-Guard** | Detects prompt injection attacks | risk > 0.8 |
| **Turn Limit** | Limits conversation turns for regular users | 10 turns max |
| **Langfuse** | Sends traces to Langfuse for observability | Auto-configured |

---

## Available Models

19 AWS Bedrock models synced - filtered to exclude:
- Cross-region inference models
- DeepSeek models

### Available models include:
- Claude 3.5 Sonnet v2
- Claude 3 Opus
- Claude 3 Haiku
- Titan models
- Mistral models
- And other AWS Bedrock models

---

## OIDC Configuration

### Open WebUI Client
- **Discovery URL:** https://auth.openwebui.demos.apps.equal.expert/realms/aiportal/.well-known/openid-configuration
- **Client ID:** openwebui
- **Client Secret:** openwebui-secret-change-this

### Langfuse Client
- **Discovery URL:** https://auth.openwebui.demos.apps.equal.expert/realms/aiportal/.well-known/openid-configuration
- **Client ID:** langfuse
- **Client Secret:** langfuse-secret-change-this

---

## Active Directory

- **Domain:** corp.aiportal.local
- **Directory ID:** d-9c67420cb4

---

## Infrastructure URLs Summary

| Service | URL |
|---------|-----|
| Open WebUI | https://portal.openwebui.demos.apps.equal.expert |
| Keycloak | https://auth.openwebui.demos.apps.equal.expert |
| Keycloak Admin | https://auth.openwebui.demos.apps.equal.expert/admin |
| Langfuse | https://langfuse.openwebui.demos.apps.equal.expert |

---

## SSH Access

```bash
# Open WebUI
ssh ec2-user@<open-webui-ip>

# Keycloak
ssh ec2-user@<keycloak-ip>

# Langfuse
ssh ec2-user@<langfuse-ip>

# Bedrock Gateway
ssh ec2-user@<bedrock-gateway-ip>
```

Get IPs with:
```bash
aws-vault exec ee-sso -- terraform output
```

---

## Database

- **Type:** PostgreSQL (RDS)
- **Databases:** aiportal, keycloak, langfuse
- **Username:** aiportaladmin
- **Password:** YourSecurePassword123
