# AI Portal - Deployment Checkpoints

This document outlines exactly what gets created, configured, and automated when you run `terraform apply`.

## 🚀 What To Expect When You Provision

### Total Deployment Time: 25-35 minutes

All components are **fully automated** - no manual intervention required.

---

## Infrastructure Created

### AWS Resources

- ✅ **VPC** (10.0.0.0/16)
  - 2 public subnets (10.0.0.0/24, 10.0.1.0/24)
  - 2 private subnets (10.0.10.0/24, 10.0.11.0/24)
  - Multi-AZ deployment across 2 availability zones

- ✅ **Networking**
  - Internet Gateway
  - NAT Gateway
  - Route tables configured

- ✅ **RDS PostgreSQL** (db.t3.medium)
  - Database: `aiportal` (Open WebUI data)
  - Database: `keycloak` (Keycloak configuration)
  - Automated backups (7-day retention)
  - Encryption at rest

- ✅ **AWS Managed Microsoft AD**
  - Domain: `corp.aiportal.local`
  - Directory Service enabled for API access
  - LDAP accessible from Keycloak

- ✅ **Application Load Balancer**
  - TLS 1.3 termination
  - Host-based routing:
    - `ai.forora.com` → Open WebUI
    - `auth.forora.com` → Keycloak
  - HTTP to HTTPS redirect

- ✅ **ACM SSL Certificate**
  - Covers: `ai.forora.com` and `auth.forora.com`
  - DNS validation

- ✅ **Route53 DNS Records**
  - A record: `ai.forora.com` → ALB
  - A record: `auth.forora.com` → ALB

- ✅ **EC2 Instances** (3 total)
  - Open WebUI: t3.large (public subnet)
  - Keycloak: t3.small (public subnet)
  - Bedrock Gateway: t3.large (public subnet)
  - All encrypted EBS volumes (30 GB gp3)

- ✅ **Security Groups**
  - ALB: 80, 443 from internet
  - Open WebUI: 8080 from ALB only
  - Keycloak: 8080 from ALB, 389 to AD
  - Bedrock Gateway: 8000 from VPC
  - RDS: 5432 from Open WebUI and Keycloak only
  - AD: LDAP/Kerberos/DNS from VPC

- ✅ **IAM Roles**
  - EC2 instances have Bedrock API permissions:
    - `bedrock:InvokeModel`
    - `bedrock:InvokeModelWithResponseStream`
    - `bedrock:ListFoundationModels`
    - `bedrock:GetFoundationModel`

---

## Keycloak (auth.forora.com) - Fully Automated

### What Gets Configured Automatically

**Database:**
- ✅ `keycloak` database created in RDS PostgreSQL
- ✅ Connection via SSL (sslmode=require)
- ✅ Schema initialized on first start

**Container:**
- ✅ Keycloak 26.0 running in Docker
- ✅ Systemd service for auto-restart
- ✅ Health endpoint enabled at `/health`

**Realm Configuration:**
- ✅ Realm created: `aiportal`
- ✅ Display name: "AI Portal"
- ✅ Login theme: keycloak
- ✅ SSL required: external

**LDAP Federation:**
- ✅ Provider: Active Directory
- ✅ Connection URL: `ldap://[AD DNS IP]`
- ✅ Base DN: `OU=Users,OU=corp,DC=corp,DC=aiportal,DC=local`
- ✅ Bind DN: `Admin@corp.aiportal.local`
- ✅ Bind credentials configured
- ✅ User attribute mapping:
  - Username: `sAMAccountName`
  - RDN: `cn`
  - UUID: `objectGUID`
- ✅ Edit mode: READ_ONLY
- ✅ Sync mode: IMPORT (read from AD, don't write back)
- ✅ Full user sync triggered automatically

**OIDC Client:**
- ✅ Client ID: `openwebui`
- ✅ Client name: "Open WebUI"
- ✅ Client secret: `openwebui-secret-change-this`
- ✅ Protocol: openid-connect
- ✅ Access type: confidential
- ✅ Standard flow: enabled
- ✅ Direct access grants: enabled
- ✅ Redirect URIs:
  - `https://ai.forora.com/*`
  - `https://ai.forora.com/oauth/oidc/callback`
- ✅ Web origins: `https://ai.forora.com`

**Protocol Mappers:**
- ✅ Email mapper (user.attribute → email claim)
- ✅ Name mapper (full name)
- ✅ Username mapper (preferred_username claim)

### Access Information

- **Admin Console:** https://auth.forora.com/admin
- **Admin Username:** `admin`
- **Admin Password:** (from `keycloak_admin_password` in terraform.tfvars)
- **OIDC Discovery:** https://auth.forora.com/realms/aiportal/.well-known/openid-configuration

---

## Open WebUI (ai.forora.com) - Fully Automated

### What Gets Configured Automatically

**Container:**
- ✅ Open WebUI (ghcr.io/open-webui/open-webui:main)
- ✅ Running on port 8080
- ✅ Docker Compose managed
- ✅ Systemd service for auto-restart

**Database:**
- ✅ Connected to RDS PostgreSQL database `aiportal`
- ✅ Schema auto-initialized
- ✅ SQLite disabled (uses PostgreSQL only)

**SSO Integration:**
- ✅ OIDC provider: Keycloak
- ✅ Provider URL: `https://auth.forora.com/realms/aiportal/.well-known/openid-configuration`
- ✅ Client ID: `openwebui`
- ✅ Client secret: `openwebui-secret-change-this`
- ✅ Local login form: **DISABLED** (SSO only)
- ✅ OAuth signup: **ENABLED** (auto-create users on first login)
- ✅ Self-registration: **DISABLED**

**Backend Configuration:**
- ✅ Ollama base URL: `http://[Bedrock Gateway Private IP]:8000`
- ✅ Chat history saving: **DISABLED**
- ✅ Data directory: `/app/backend/data`

**Models Automatically Synced:**
- ✅ 23 Bedrock models synced to database
- ✅ All models set to `is_active = 1` (enabled)
- ✅ Access control set to `NULL` (available to all users)

**Models Include:**
- Claude Sonnet 4.5 (v2, Inference Profile)
- Claude Haiku 4.5 (v2)
- Claude 3.7 Sonnet
- Claude 3 Sonnet
- Claude 3 Haiku
- Amazon Nova (Micro, Lite, Pro)
- Llama 3.1 (8B, 70B, 405B Instruct)
- Llama 3.2 (1B, 3B, 11B, 90B Vision Instruct)
- Mistral (7B, Large 2)
- Qwen 2.5 (72B Instruct)

### Access Information

- **Portal URL:** https://ai.forora.com
- **Login Method:** SSO only (redirects to Keycloak)
- **Direct URL:** http://[Open WebUI Public IP]:8080 (bypasses ALB)

---

## Bedrock Gateway - Fully Automated

### What Gets Configured Automatically

**Application:**
- ✅ FastAPI service running as systemd daemon
- ✅ Service name: `bedrock-gateway`
- ✅ Auto-start on boot
- ✅ Auto-restart on failure

**API Endpoints:**
- ✅ `/api/tags` - List all available models
- ✅ `/api/generate` - Generate text completion
- ✅ `/api/chat` - Chat completion (streaming)
- ✅ `/health` - Health check endpoint

**Features:**
- ✅ Ollama-compatible API (works with Open WebUI)
- ✅ Dynamic model discovery from Bedrock API
- ✅ Model filtering (excludes embeddings, images, DeepSeek)
- ✅ Inference profile handling for Claude 4.5+
- ✅ Automatic region detection (eu-west-2)
- ✅ IAM role-based authentication (no API keys needed)

**Model Discovery:**
- ✅ Queries Bedrock API hourly
- ✅ Filters by provider (Anthropic, Amazon, Meta, Mistral AI, Qwen)
- ✅ Excludes cross-region-only models
- ✅ ON_DEMAND models only

### Access Information

- **Internal URL:** http://[Bedrock Gateway Private IP]:8000
- **Health Check:** http://[Bedrock Gateway Private IP]:8000/health
- **Not publicly accessible** (private VPC access only)

---

## Active Directory Users - Automatically Created

### Admin User (Admin Role)

**In Active Directory:**
- ✅ SAM Account Name: `Admin`
- ✅ Given Name: `Admin`
- ✅ Surname: `User`
- ✅ Email: `Admin@corp.aiportal.local`
- ✅ Password: `Welcome@2024`
- ✅ Enabled: `true`

**In Keycloak:**
- ✅ Synced via LDAP federation
- ✅ Username: `admin`
- ✅ Email: `admin@corp.aiportal.local`
- ✅ Authentication: LDAP (validates against AD)

**In Open WebUI:**
- ✅ Created programmatically in database
- ✅ Email: `admin@corp.aiportal.local`
- ✅ Role: `admin`
- ✅ Name: `Admin`
- ✅ No password stored (SSO only)

**Login:**
- Username: `Admin` (or `admin`)
- Password: `Welcome@2024`
- Role: **Admin** (full access)

### Test User (Regular User)

**In Active Directory:**
- ✅ SAM Account Name: `testuser`
- ✅ Given Name: `Test`
- ✅ Surname: `User`
- ✅ Email: `testuser@corp.aiportal.local`
- ✅ Password: `Welcome@2024`
- ✅ Enabled: `true`

**In Keycloak:**
- ✅ Synced via LDAP federation
- ✅ Username: `testuser`
- ✅ Email: `testuser@corp.aiportal.local`
- ✅ Authentication: LDAP (validates against AD)

**In Open WebUI:**
- ✅ Created automatically on first SSO login
- ✅ Email: `testuser@corp.aiportal.local`
- ✅ Role: `user` (regular user)
- ✅ No password stored (SSO only)

**Login:**
- Username: `testuser`
- Password: `Welcome@2024`
- Role: **User** (regular access)

---

## What You Can Do Immediately After Deployment

### Step 1: Wait for Deployment (25-35 minutes)

Watch terraform output. When complete, you'll see:
```
Apply complete! Resources: XX added, 0 changed, 0 destroyed.

Outputs:

ai_portal_url = "https://ai.forora.com"
keycloak_admin_console = "https://auth.forora.com/admin"
...
```

### Step 2: Access the Portal

1. **Open:** https://ai.forora.com
2. **Click:** SSO button (no username/password form shown)
3. **Redirected to:** https://auth.forora.com (Keycloak)

### Step 3: Login as Admin

**On Keycloak login page:**
- Username: `Admin`
- Password: `Welcome@2024`

**Redirected back to Open WebUI:**
- ✅ Logged in as Admin
- ✅ Admin role active
- ✅ All 23 models visible in dropdown
- ✅ Ready to chat

### Step 4: (Optional) Login as Test User

**Logout and login again:**
- Username: `testuser`
- Password: `Welcome@2024`

**Logged in as regular user:**
- ✅ User role
- ✅ All models visible
- ✅ Can chat with AI

### Step 5: Start Using AI Models

1. Select a model from dropdown (e.g., "Claude Sonnet 4.5")
2. Type a message
3. Get AI response
4. Chat history saved in PostgreSQL

---

## Verification Commands

### Get All Outputs

```bash
terraform output
```

### Get Specific URLs

```bash
terraform output ai_portal_url
terraform output keycloak_admin_console
terraform output bedrock_gateway_url
```

### SSH Into Instances

```bash
# Open WebUI
ssh ec2-user@$(terraform output -raw open_webui_public_ip)

# Keycloak
ssh ec2-user@$(terraform output -raw keycloak_public_ip)

# Bedrock Gateway
ssh ec2-user@$(terraform output -raw bedrock_gateway_public_ip)
```

### Check Service Health

```bash
# Portal
curl -I https://ai.forora.com
# Should return: HTTP/2 200

# Keycloak
curl -s https://auth.forora.com/health
# Should return: {"error":"Unable to find matching target resource method"}
# (This is normal - means Keycloak is up)

# Keycloak OIDC config
curl -s https://auth.forora.com/realms/aiportal/.well-known/openid-configuration | jq
# Should return JSON with issuer, endpoints, etc.

# Bedrock Gateway (from Open WebUI instance)
ssh ec2-user@$(terraform output -raw open_webui_public_ip) \
  "curl -s http://10.0.0.14:8000/health"
# Should return: {"status":"healthy"}
```

### Check Users in Open WebUI Database

```bash
ssh ec2-user@$(terraform output -raw open_webui_public_ip) \
  "sudo docker exec -i open-webui python3 <<'EOF'
import os
os.environ['DATA_DIR'] = '/app/backend/data'
from open_webui.internal.db import engine
from sqlalchemy import text
with engine.connect() as conn:
    result = conn.execute(text('SELECT email, role FROM user'))
    for row in result:
        print(f'{row[0]:40} {row[1]}')
EOF
"
```

Expected output:
```
admin@corp.aiportal.local                admin
testuser@corp.aiportal.local             user
```

### Check Models Synced

```bash
ssh ec2-user@$(terraform output -raw open_webui_public_ip) \
  "sudo docker exec -i open-webui python3 <<'EOF'
import os
os.environ['DATA_DIR'] = '/app/backend/data'
from open_webui.internal.db import engine
from sqlalchemy import text
with engine.connect() as conn:
    result = conn.execute(text('SELECT COUNT(*) FROM model WHERE is_active = 1'))
    print(f'Active models: {result.fetchone()[0]}')
EOF
"
```

Expected output:
```
Active models: 23
```

---

## Deployment Timeline

| Time | Component | What's Happening |
|------|-----------|------------------|
| 0-2 min | VPC | Creating VPC, subnets, route tables |
| 2-5 min | Networking | Creating IGW, NAT Gateway |
| 5-15 min | AWS Managed AD | Creating directory (slowest component) |
| 5-12 min | RDS | Creating PostgreSQL instance |
| 8-15 min | ALB + ACM | Creating load balancer, validating certificate |
| 12-15 min | EC2 | Launching 3 instances |
| 15-17 min | Keycloak Userdata | Installing Docker, PostgreSQL client, jq |
| 17-18 min | Keycloak Database | Creating `keycloak` database in RDS |
| 18-19 min | Keycloak Start | Starting Docker container, initializing schema |
| 19-20 min | Keycloak Config | Creating realm, LDAP federation, OIDC client |
| 20-21 min | Open WebUI Userdata | Installing Docker, waiting for Keycloak |
| 21-22 min | Admin User | Creating Admin in AD, syncing to Keycloak, creating in DB |
| 22-23 min | Test User | Creating testuser in AD |
| 23-24 min | Model Sync | Syncing 23 Bedrock models to database |
| 24-25 min | Open WebUI Start | Starting Docker container |
| 25-30 min | Stabilization | All services healthy and ready |

---

## Zero Manual Steps Required

### ❌ Things You DON'T Need To Do

- ❌ Manually create Keycloak realm
- ❌ Manually configure LDAP federation
- ❌ Manually create OIDC client
- ❌ Manually create Admin user
- ❌ Manually promote users to admin
- ❌ Manually sync models
- ❌ Manually create database
- ❌ Manually fix any configuration files
- ❌ Manually restart any services
- ❌ Manually test LDAP authentication
- ❌ Manually set passwords

### ✅ What IS Automated

- ✅ ALL infrastructure provisioning
- ✅ ALL database creation
- ✅ ALL service configuration
- ✅ ALL user creation
- ✅ ALL LDAP/OIDC setup
- ✅ ALL model synchronization
- ✅ ALL role assignments
- ✅ ALL health checks

---

## Troubleshooting (Should Not Be Needed)

If something fails (it shouldn't), check:

### Keycloak Not Starting

```bash
ssh ec2-user@$(terraform output -raw keycloak_public_ip)
sudo docker logs keycloak
```

Common issue: Database doesn't exist
- **Fixed:** Script now connects to `postgres` database to create `keycloak` database

### Open WebUI Not Starting

```bash
ssh ec2-user@$(terraform output -raw open_webui_public_ip)
sudo docker logs open-webui
```

Common issue: Keycloak not ready
- **Fixed:** Script waits up to 10 minutes for Keycloak health check

### Models Not Showing

```bash
ssh ec2-user@$(terraform output -raw bedrock_gateway_public_ip)
sudo journalctl -u bedrock-gateway -f
```

Common issue: Bedrock model access not enabled
- **Solution:** Enable in AWS Console > Bedrock > Model access

### Admin User Wrong Role

```bash
# Check user roles
ssh ec2-user@$(terraform output -raw open_webui_public_ip) \
  "sudo docker exec open-webui python3 -c 'import os; os.environ[\"DATA_DIR\"]=\"/app/backend/data\"; from open_webui.internal.db import engine; from sqlalchemy import text; conn = engine.connect(); [print(row) for row in conn.execute(text(\"SELECT email, role FROM user\"))]'"
```

Common issue: testuser logged in first
- **Fixed:** Script creates Admin in database programmatically before testuser

---

## Cost Estimate

**Hourly:** ~£1.90/hour
**Daily:** ~£46/day
**Monthly:** ~£1,400/month

**Breakdown:**
- AWS Managed AD: ~£1.00/hour
- RDS db.t3.medium: ~£0.15/hour
- EC2 instances (3x): ~£0.30/hour
- NAT Gateway: ~£0.30/hour
- ALB: ~£0.15/hour
- Bedrock usage: Variable (pay per token)

**To reduce costs:**
- Destroy when not in use: `terraform destroy`
- Use smaller instance types (edit terraform.tfvars)
- Use spot instances (not recommended for production)

---

## Success Criteria

After deployment completes, you should be able to:

1. ✅ Visit https://ai.forora.com and see SSO login
2. ✅ Login as `Admin` with password `Welcome@2024`
3. ✅ See 23 models in the dropdown
4. ✅ Select a model and send a chat message
5. ✅ Receive AI response
6. ✅ Logout and login as `testuser`
7. ✅ Verify testuser has user role (not admin)
8. ✅ Visit https://auth.forora.com/admin
9. ✅ Login to Keycloak admin console
10. ✅ See realm `aiportal` with LDAP federation and OIDC client

**If all 10 criteria pass: Deployment is 100% successful.**

---

## What Changed From Previous Versions

### Version 2.1 (Current) - 2025-11-19

**Critical Fixes:**

1. **Keycloak Database Bug Fixed**
   - **Problem:** Script tried to connect to `keycloak` database to CREATE it (impossible)
   - **Solution:** Connect to `postgres` admin database instead
   - **Files:** `main.tf`, `userdata_keycloak.sh`
   - **Impact:** Keycloak now starts successfully on first boot

2. **Admin User Creation Fixed**
   - **Problem:** testuser logged in first and became admin
   - **Solution:** Create Admin user in AD first, then programmatically create in Open WebUI DB with admin role
   - **Files:** `userdata_open_webui.sh`
   - **Impact:** Admin = admin role, testuser = user role (correct)

**Result:** Deployment is now truly fully automated with no manual intervention required.

---

**Version:** 2.1
**Last Updated:** 2025-11-19
**Status:** ✅ Fully Automated and Production Ready
