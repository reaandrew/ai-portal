# AI Portal - AWS Infrastructure

Complete Terraform infrastructure for AI Portal on AWS with Open WebUI, AWS Bedrock integration, PostgreSQL RDS, Keycloak SSO, and Active Directory authentication.

## ✅ Keycloak SSO Authentication - FULLY AUTOMATED

**Single Sign-On (SSO) via Keycloak is fully automated and production-ready.** Users authenticate through Keycloak which federates to Active Directory via LDAP, providing enterprise-grade authentication with centralized identity management.

### Key Features

1. **Keycloak as Identity Provider (IdP)** - Centralized authentication and user management
2. **LDAP Federation to Active Directory** - Seamless integration with existing AD infrastructure
3. **OpenID Connect (OIDC)** - Modern authentication protocol
4. **Fully Automated Setup** - Keycloak realm, LDAP config, and OIDC client created automatically
5. **No Local Password Storage** - All authentication handled by Keycloak + AD

**Authentication Flow:** `User → Open WebUI → Keycloak → Active Directory → OIDC tokens → Authenticated`

---

## 🎯 What's Required vs Optional

### ✅ REQUIRED Files (In This Directory)

**These 9 files are ALL you need to deploy:**

```
main.tf                          # Infrastructure definition
variables.tf                     # Variable declarations
outputs.tf                       # Output values
userdata_keycloak.sh            # Keycloak EC2 bootstrap (referenced in main.tf)
userdata_open_webui.sh          # Open WebUI EC2 bootstrap (referenced in main.tf)
userdata_bedrock_gateway.sh     # Bedrock Gateway EC2 bootstrap (referenced in main.tf)
userdata_langfuse.sh            # Langfuse EC2 bootstrap (referenced in main.tf)
sync_models.sh                   # Sync Bedrock models to Open WebUI (run after deploy)
terraform.tfvars                 # Your passwords & config (stored in AWS SSM)
terraform.tfvars.example         # Template for tfvars
```

### ❌ OPTIONAL Scripts (In Parent Directory)

**These are convenience wrappers - you can do everything they do with AWS CLI/Terraform:**

```
../deploy.sh                     # Wrapper for: terraform init && terraform apply
../destroy.sh                    # Wrapper for: terraform destroy
../status.sh                     # Wrapper for: terraform output + aws cli
../create_ad_user.sh            # Wrapper for: aws ds-data create-user
../set_ad_admin.sh              # Wrapper for: SSH + database UPDATE
../update_ssm_tfvars.sh         # Wrapper for: aws ssm put-parameter
../post_deploy_setup.sh         # Automated post-deploy workflow
```

---

## 🏗️ Infrastructure Overview

**Components:**
- **4x EC2 Instances** - Open WebUI (t3.large), Keycloak (t3.small), Bedrock Gateway (t3.large), Langfuse (t3.medium)
- **RDS PostgreSQL (db.t3.medium)** - Shared database (3 databases: `aiportal`, `keycloak`, `langfuse`)
- **AWS Managed Microsoft AD** - Active Directory for user authentication
- **Keycloak (Docker)** - Identity Provider with LDAP federation
- **Langfuse (Docker)** - LLM Observability and tracing
- **Application Load Balancer** - TLS 1.3 termination with host-based routing
- **ACM Certificate** - SSL/TLS for all subdomains
- **VPC with public/private subnets** - Network isolation
- **NAT Gateway** - Outbound internet for private resources
- **Security Groups** - Network access control
- **IAM Roles** - Bedrock API permissions

**Access:**
- **Open WebUI:** https://ai.forora.com (TLS 1.3, HTTPS only)
- **Keycloak Admin:** https://auth.forora.com/admin
- **Langfuse:** https://langfuse.forora.com (LLM Observability)

**Cost:** ~£1.90/hour (~£46/day) + Bedrock token usage

---

## 🛡️ Pipeline Filters (Security & Observability)

Open WebUI includes four automated pipeline filters that intercept all LLM requests:

| Filter | Priority | Function | Applies To |
|--------|----------|----------|------------|
| **Detoxify Filter** | 0 | Blocks toxic/harmful messages using ML model | All models |
| **LLM-Guard Filter** | 1 | Detects and blocks prompt injection attacks | All models |
| **Turn Limit Filter** | 2 | Limits conversation turns (default: 10) | All users (user + admin roles) |
| **Langfuse Filter** | 0 | LLM observability with token usage tracking | All models |

### Critical Configuration Notes

**⚠️ IMPORTANT: Valves `pipelines` Class Default**

All filter pipelines MUST have `pipelines: List[str] = ["*"]` as the **class default** in the Valves definition:

```python
class Pipeline:
    class Valves(BaseModel):
        pipelines: List[str] = ["*"]  # MUST be ["*"] - NOT []
```

If `pipelines` is empty `[]`, the filter will **never be invoked**. This is a common gotcha when copying pipeline examples.

**WebSocket Support Disabled**

WebSocket support is disabled (`ENABLE_WEBSOCKET_SUPPORT=false`) for compatibility with some load balancer configurations. The UI uses HTTP polling instead.

---

## Prerequisites

1. **AWS Account** with permissions for EC2, RDS, Directory Service, IAM, Route53, ACM, ELB, Bedrock
2. **AWS CLI** configured (`aws configure` or `aws-vault`)
3. **Terraform** >= 1.0
4. **Route53 Hosted Zone** for your domain (forora.com)
5. **Bedrock Model Access** enabled in AWS Console (Anthropic Claude models)

### Enable Bedrock Model Access

**CRITICAL:** Do this BEFORE deployment:

```bash
# 1. Go to: AWS Console > Bedrock > Model access
# 2. Click "Manage model access"
# 3. Enable: Claude Sonnet 4.5, Claude Haiku 4.5, Claude 3.7 Sonnet, Claude 3 Sonnet, Claude 3 Haiku
# 4. Submit (usually instant approval)

# Verify:
aws-vault exec personal -- aws bedrock list-foundation-models \
  --region eu-west-2 \
  --by-provider anthropic
```

---

## 🚀 Quick Start

### 1. Get terraform.tfvars (From AWS SSM)

```bash
aws-vault exec personal -- aws ssm get-parameter \
  --name "/com/forora/ai-portal/terraform.tfvars" \
  --with-decryption \
  --region eu-west-2 \
  --query 'Parameter.Value' \
  --output text > terraform.tfvars
```

**OR create from scratch:**

```bash
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars  # Edit with your values
```

Required in terraform.tfvars:
- `ssh_public_key` - Your public SSH key
- `db_password` - Strong database password (12+ chars, **avoid `!`**)
- `ad_admin_password` - Strong AD password (8+ chars, **can include `!`**)
- `keycloak_admin_password` - Keycloak admin password (8+ chars, **avoid `!`**)
- `domain_name` - Your Route53 domain (default: forora.com)
- `subdomain` - Subdomain for Open WebUI (default: ai)
- `keycloak_subdomain` - Subdomain for Keycloak (default: auth)

### 2. Deploy Infrastructure

```bash
# Initialize Terraform (uses S3 backend automatically)
terraform init

# Review plan
terraform plan

# Deploy (takes 20-30 minutes)
terraform apply
```

### 3. Wait for Userdata Scripts

EC2 instances run bootstrap scripts on first boot. Timeline:
- **Keycloak**: ~2 minutes (database creation + container start + LDAP config + OIDC client)
- **Open WebUI**: ~2 minutes (waits for Keycloak to be ready + model sync)

**Admin user is created automatically!** The Open WebUI userdata script:
1. Waits for Keycloak to be ready (max 10 minutes)
2. Enables Directory Service Data Access
3. Creates `Admin` user with:
   - Email: `admin@corp.aiportal.local` (REQUIRED for OAuth/OIDC login)
   - Password: `ad_admin_password` from terraform.tfvars (also used as LDAP bind credential)
4. Syncs users from AD to Keycloak via LDAP

### 4. Access Portal & Login

```bash
terraform output ai_portal_url
# Output: https://ai.forora.com
```

**SSO Login Flow:**
1. Visit https://ai.forora.com
2. Click the **SSO** button (no username/password form shown)
3. Redirected to Keycloak at https://auth.forora.com
4. Enter AD credentials:
   - **Admin user**: Username: `admin`, Password: (value of `ad_admin_password` from terraform.tfvars, default: `YourSecureADPassword123`)
   - **Test user**: Create manually with `aws ds-data create-user` and ensure email is set
5. Keycloak authenticates against Active Directory
6. Redirected back to Open WebUI with OIDC tokens
7. ✅ Logged in!

**IMPORTANT:**
- Login with `admin` user FIRST to make them the admin in Open WebUI
- **Email is REQUIRED**: Open WebUI OAuth requires users to have an email address in Active Directory
- The LDAP mapper syncs the `mail` attribute from AD to Keycloak's `email` field

**No local password storage** - All authentication handled by Keycloak + AD

### 5. Models Are Synced Automatically! ✅

The userdata script now **automatically syncs models** during deployment:
- Waits for Bedrock Gateway to be ready (max 5 minutes)
- Syncs all 23 models to Open WebUI's database
- Sets proper permissions (available to all users)

**No manual action required!** Models will be ready when you login.

**If models don't appear** (rare), run manually:
```bash
./sync_models.sh
# OR: ./sync_models.sh $(terraform output -raw open_webui_public_ip)
```

**What gets synced:**
- 23 Bedrock models (Claude, Nova, Llama, Mistral, Qwen, etc.)
- Excludes: DeepSeek, embed, image, and cross-region-only models
- Sets `is_active=1` and `access_control=NULL` (available to all users)

---

## 📊 Deployment Timeline

| Step | Duration | Notes |
|------|----------|-------|
| VPC & Networking | 2-3 min | VPC, subnets, IGW, NAT |
| AWS Managed AD | 10-15 min | Slowest component |
| RDS PostgreSQL | 5-7 min | Database creation (2 databases) |
| EC2 Instances | 3-5 min | 3 instances (Open WebUI, Keycloak, Gateway) |
| ALB + Certificate | 2-3 min | DNS validation for both subdomains |
| Keycloak Setup | ~2 min | Database + LDAP + OIDC client (via userdata) |
| Open WebUI Setup | ~2 min | Wait for Keycloak + model sync (via userdata) |
| **Total** | **25-35 min** | First deployment |

---

## 🔧 Post-Deployment Tasks

### Promote User to Admin (Optional)

User must login via web interface FIRST, then:

**Option 1: Helper script**
```bash
../set_ad_admin.sh testuser@corp.aiportal.local
```

**Option 2: Manual**
```bash
WEBUI_IP=$(terraform output -raw open_webui_public_ip)
DB_ENDPOINT=$(terraform output -raw rds_endpoint | cut -d':' -f1)
DB_NAME=$(terraform output -raw rds_database_name)
DB_USER=$(grep '^db_username' terraform.tfvars | cut -d'=' -f2 | tr -d ' "')
DB_PASSWORD=$(grep '^db_password' terraform.tfvars | cut -d'=' -f2 | tr -d ' "')

ssh -o StrictHostKeyChecking=no ec2-user@$WEBUI_IP "sudo docker exec -i open-webui python3 <<EOF
import os
os.environ['DATABASE_URL'] = 'postgresql://${DB_USER}:${DB_PASSWORD}@${DB_ENDPOINT}:5432/${DB_NAME}'
from sqlalchemy import create_engine, text
engine = create_engine(os.environ['DATABASE_URL'])
with engine.connect() as conn:
    conn.execute(text(\"UPDATE user SET role = 'admin' WHERE email = 'testuser@corp.aiportal.local'\"))
    conn.commit()
EOF
"
```

### Access Keycloak Admin Console

**URL:** https://auth.forora.com/admin

**Credentials:**
- Username: `admin`
- Password: (value of `keycloak_admin_password` from terraform.tfvars)

**From Keycloak Admin, you can:**
- Manage users and groups
- View LDAP sync status: User Federation → active-directory → Sync users
- Test LDAP authentication: User Federation → active-directory → Test authentication
- View authentication logs: Realm settings → Events
- Modify OIDC client settings: Clients → openwebui
- Change client secret: Clients → openwebui → Credentials tab

**OIDC Configuration URL:** https://auth.forora.com/realms/aiportal/.well-known/openid-configuration

### Verify Services

```bash
# Check status
../status.sh  # OR: terraform output

# SSH into instances
ssh -i ~/.ssh/ai-portal-key ec2-user@$(terraform output -raw open_webui_public_ip)
ssh -i ~/.ssh/ai-portal-key ec2-user@$(terraform output -raw keycloak_public_ip)
ssh -i ~/.ssh/ai-portal-key ec2-user@$(terraform output -raw bedrock_gateway_public_ip)

# Check Keycloak
ssh ec2-user@$(terraform output -raw keycloak_public_ip)
sudo docker logs keycloak
curl http://localhost:8080/health/ready  # Should return: {"status":"UP"}

# Check Open WebUI
ssh ec2-user@$(terraform output -raw open_webui_public_ip)
sudo docker logs open-webui
sudo docker ps

# Check Bedrock Gateway
ssh ec2-user@$(terraform output -raw bedrock_gateway_public_ip)
sudo systemctl status bedrock-gateway
sudo journalctl -u bedrock-gateway -f

# Test health endpoints
curl http://$(terraform output -raw bedrock_gateway_private_ip):8000/health
curl https://auth.forora.com/health/ready  # Keycloak via ALB
```

---

## 🗑️ Teardown

```bash
terraform destroy

# Type 'yes' to confirm
```

**What gets deleted:**
- All EC2 instances and data
- RDS database
- AWS Managed AD
- VPC and networking
- Load balancer
- Route53 A record (NOT the hosted zone)
- ACM certificate
- Security groups and IAM roles

**What survives:**
- Route53 hosted zone
- S3 backend bucket (`ai-portal-terraform-state-276447169330`)
- DynamoDB lock table (`ai-portal-terraform-locks`)
- SSM Parameter (`/com/forora/ai-portal/terraform.tfvars`)

---

## 💾 Backend Configuration

**State Storage:** S3 bucket with versioning and encryption
- Bucket: `ai-portal-terraform-state-276447169330`
- Key: `ai-portal/terraform.tfstate`
- Region: `eu-west-2`
- Encryption: AES256
- Locking: DynamoDB table `ai-portal-terraform-locks`

**Benefits:**
- State is safe even if local machine dies
- Team collaboration with shared state
- State locking prevents concurrent modifications
- Versioning for rollback

---

## 🔐 Secrets Management

**terraform.tfvars** contains sensitive data and is:
- ✅ Excluded from git (`.gitignore`)
- ✅ Stored in AWS SSM Parameter Store: `/com/forora/ai-portal/terraform.tfvars`
- ✅ Encrypted with AWS KMS

**To update SSM backup:**
```bash
../update_ssm_tfvars.sh
# OR manually:
aws-vault exec personal -- aws ssm put-parameter \
  --name "/com/forora/ai-portal/terraform.tfvars" \
  --value "file://$PWD/terraform.tfvars" \
  --type "SecureString" \
  --overwrite \
  --region eu-west-2
```

---

## 🔍 Troubleshooting

### Open WebUI Not Responding

```bash
ssh -i ~/.ssh/ai-portal-key ec2-user@$(terraform output -raw open_webui_public_ip)
sudo docker ps
sudo docker logs open-webui -f
cd /opt/open-webui && sudo docker-compose restart
```

### Bedrock Models Not Showing

```bash
# 1. Check model access in AWS Console
# 2. Check gateway logs
ssh -i ~/.ssh/ai-portal-key ec2-user@$(terraform output -raw bedrock_gateway_public_ip)
sudo journalctl -u bedrock-gateway -n 100

# 3. Test manually
curl http://localhost:8000/api/tags | jq
```

### Keycloak SSO Troubleshooting

**✅ Keycloak SSO is fully automated and configured during deployment**

#### No SSO Button on Login Page

**Symptom:** Username/password form shows instead of SSO button

**Check:**
```bash
ssh ec2-user@$(terraform output -raw open_webui_public_ip)
cat /opt/open-webui/.env | grep -E "OPENID_PROVIDER_URL|ENABLE_LOGIN_FORM"
```

**Should show:**
```
OPENID_PROVIDER_URL=https://auth.forora.com/realms/aiportal/.well-known/openid-configuration
ENABLE_LOGIN_FORM=false
```

**Fix:**
```bash
cd /opt/open-webui
# Verify .env is correct
sudo nano .env  # Check OPENID_PROVIDER_URL and ENABLE_LOGIN_FORM
# Recreate container (restart doesn't reload .env!)
sudo docker-compose down && sudo docker-compose up -d
# Clear browser cache / hard refresh
```

#### OAuth Login Fails: "Email or password provided is incorrect"

**Symptom:** Login redirects to Keycloak successfully but Open WebUI shows email/password error

**Root Cause:** Open WebUI requires users to have an email address, but the user in Active Directory has no email set.

**Check Open WebUI logs:**
```bash
ssh ec2-user@$(terraform output -raw open_webui_public_ip)
sudo docker logs open-webui 2>&1 | grep -i "oauth\|email"
# Look for: "OAuth callback failed, email is missing"
```

**Fix - Add email to user in AD:**
```bash
# For admin user
aws ds-data update-user \
  --directory-id $(terraform output -raw active_directory_id) \
  --sam-account-name Admin \
  --email-address "admin@corp.aiportal.local" \
  --region eu-west-2

# Trigger LDAP sync in Keycloak to pull updated email
# (Use Keycloak Admin Console → User Federation → active-directory → Sync all users)
```

**Prevention:** The userdata script now automatically sets email for Admin user. For additional users, always include `--email-address` when creating them.

#### LDAP Authentication Fails in Keycloak

**Symptom:** Login redirects to Keycloak but fails with authentication error

**Check LDAP config in Keycloak Admin:**
1. Login to https://auth.forora.com/admin
2. Go to: User Federation → active-directory
3. Click "Test authentication" button
4. Enter: Username=`admin`, Password=`YourSecureADPassword123`
5. Should show "Success"

**If fails:**
```bash
ssh ec2-user@$(terraform output -raw keycloak_public_ip)
sudo docker logs keycloak 2>&1 | tail -100

# Check AD is reachable
AD_IP=$(terraform output -raw active_directory_dns_ips | cut -d',' -f1 | tr -d '[] "')
telnet $AD_IP 389  # Should connect

# Verify bind credentials match
echo "Bind DN: Admin@corp.aiportal.local"
echo "Bind Password: (check terraform.tfvars ad_admin_password)"
```

#### Keycloak Won't Start

**Symptom:** Keycloak container not running

**Check:**
```bash
ssh ec2-user@$(terraform output -raw keycloak_public_ip)
sudo docker ps -a | grep keycloak
sudo docker logs keycloak

# Common issues:
# 1. Database connection failed
DB_ENDPOINT=$(terraform output -raw rds_endpoint | cut -d: -f1)
psql -h $DB_ENDPOINT -U aiportaladmin -d keycloak  # Test DB access

# 2. Database doesn't exist
psql -h $DB_ENDPOINT -U aiportaladmin -d postgres -c "\l" | grep keycloak

# 3. Restart container
cd /opt/keycloak
sudo docker-compose restart
```

### Troubleshooting Models Not Appearing

**Symptom:** No models visible in Open WebUI dropdown

**Solution:**
```bash
# 1. Check if Bedrock Gateway is running and returning models
ssh ec2-user@$(terraform output -raw bedrock_gateway_public_ip) \
  "curl -s http://localhost:8000/api/tags | jq '.models | length'"
# Should return: 23 (or similar number)

# 2. Check if Open WebUI can reach the gateway
ssh ec2-user@$(terraform output -raw open_webui_public_ip) \
  "curl -s http://10.0.0.28:8000/api/tags | jq '.models | length'"
# Should also return: 23

# 3. Sync models to Open WebUI database
./sync_models.sh

# 4. Verify models in database
ssh ec2-user@$(terraform output -raw open_webui_public_ip) \
  "sudo docker exec -i open-webui python3 <<'EOF'
import os
os.environ['DATA_DIR'] = '/app/backend/data'
from open_webui.internal.db import engine
from sqlalchemy import text
with engine.connect() as conn:
    result = conn.execute(text('SELECT COUNT(*) FROM model WHERE is_active = 1'))
    print(f'Active models in database: {result.fetchone()[0]}')
EOF
"
# Should return: Active models in database: 23
```

**Root Cause:** Open WebUI v0.6.36 requires models to be populated in the `model` table. Even though `OLLAMA_BASE_URL` is set correctly and the Bedrock Gateway is working, models won't appear until they're explicitly added to the database with `is_active=1` and `access_control=NULL`.

### Database Connection Issues

```bash
# Get endpoint
terraform output rds_endpoint

# Test from Open WebUI instance
ssh -i ~/.ssh/ai-portal-key ec2-user@$(terraform output -raw open_webui_public_ip)
DB_ENDPOINT=$(terraform output -raw rds_endpoint | cut -d: -f1)
psql -h $DB_ENDPOINT -U aiportaladmin -d aiportal
```

---

## 📖 Lessons Learned - Keycloak SSO Implementation (2025-11-18)

### ✅ KEYCLOAK SSO: FULLY AUTOMATED AND WORKING

After replacing direct LDAP authentication with Keycloak SSO, we now have a **fully automated, enterprise-grade authentication system** that's completely repeatable.

### Why Keycloak Instead of Direct LDAP?

**Previous approach (Direct LDAP):**
- ❌ Complex Open WebUI LDAP configuration prone to bugs
- ❌ Database table mismatch issues
- ❌ No centralized user management
- ❌ Limited SSO capabilities

**Current approach (Keycloak + LDAP Federation):**
- ✅ Keycloak handles all LDAP complexity
- ✅ Centralized identity management
- ✅ OIDC protocol (industry standard)
- ✅ No local password storage in Open WebUI
- ✅ Better audit logs and security

### Key Implementation Insights

#### Issue 1: Password Special Characters
**Lesson:** Avoid `!` in `db_password` and `keycloak_admin_password` due to shell escaping in docker-compose.yml
**Solution:** Only `ad_admin_password` can have `!` (properly escaped in LDAP config JSON)

#### Issue 2: Environment Variable Names
**Symptom:** No SSO button shown in Open WebUI
**Root Cause:** Wrong env var name (`OAUTH_DISCOVERY_URL` instead of `OPENID_PROVIDER_URL`)
**Solution:** Use `OPENID_PROVIDER_URL` and set `ENABLE_LOGIN_FORM=false`

#### Issue 3: Container Restarts Don't Reload .env
**Learning:** `docker-compose restart` does NOT reload environment variables
**Solution:** Always use `docker-compose down && docker-compose up -d` after .env changes

#### Issue 4: Keycloak Startup Command
**Problem:** `--proxy=edge` flag invalid in Keycloak 26.0
**Solution:** Use `start-dev` for development/POC deployments

### This Infrastructure IS Fully Repeatable

**One command deployment:**
1. `terraform apply`
2. Wait 25-35 minutes
3. ✅ Visit https://ai.forora.com and login with SSO!

**Everything is automated:**
- Keycloak database creation
- LDAP federation configuration
- OIDC client creation
- Test user creation in AD
- Model synchronization

### Architecture Decisions

1. **Shared PostgreSQL RDS** - Two databases (`aiportal`, `keycloak`) for cost efficiency
2. **Keycloak in Docker** - Easy updates and version management
3. **Host-based ALB routing** - Single load balancer for both services
4. **OIDC over SAML** - Simpler, more modern, better for APIs
5. **Read-only LDAP** - Keycloak doesn't modify AD, only reads

---

## 🏛️ Architecture Details

### Network Design
- **VPC**: 10.0.0.0/16
- **Public Subnets**: 10.0.0.0/24, 10.0.1.0/24 (EC2 with public IPs)
- **Private Subnets**: 10.0.10.0/24, 10.0.11.0/24 (RDS, AD)
- **Multi-AZ**: 2 availability zones for high availability

### Security Groups
- **ALB**: Allows 80 (redirect), 443 (TLS 1.3)
- **Open WebUI**: Allows 8080 from ALB only
- **Keycloak**: Allows 8080 from ALB only, LDAP (389) to AD
- **Bedrock Gateway**: Allows 8000 from VPC + SSH
- **RDS**: Allows 5432 from Open WebUI and Keycloak only
- **AD**: Allows LDAP/Kerberos/DNS from VPC

### IAM Permissions
EC2 instances have IAM role with:
- `bedrock:InvokeModel`
- `bedrock:InvokeModelWithResponseStream`
- `bedrock:ListFoundationModels`
- `bedrock:GetFoundationModel`

### Open WebUI Configuration
Environment variables set in `userdata_open_webui.sh`:
- `OLLAMA_BASE_URL` - Points to Bedrock Gateway
- `OPENID_PROVIDER_URL` - Keycloak OIDC discovery endpoint
- `OAUTH_CLIENT_ID=openwebui` - OIDC client identifier
- `OAUTH_CLIENT_SECRET` - Client secret for authentication
- `ENABLE_LOGIN_FORM=false` - Hide local login, use SSO only
- `ENABLE_OAUTH_SIGNUP=true` - Auto-create users on first SSO login
- `ENABLE_SIGNUP=false` - No self-registration
- `SAVE_CHAT_HISTORY=false` - No chat history storage

### Bedrock Gateway
FastAPI application (`userdata_bedrock_gateway.sh`):
- **Dynamic Model Discovery** - Queries Bedrock API hourly
- **Ollama-Compatible API** - Works with Open WebUI
- **Endpoints**: `/api/tags`, `/api/generate`, `/api/chat`, `/health`
- **Model Filtering** - Excludes embeddings, images, DeepSeek
- **Inference Profiles** - Auto-handles Claude 4.5+ requirements

---

## 💰 Cost Optimization

### Development/Testing
```hcl
# In terraform.tfvars
webui_instance_type    = "t3.small"    # ~$0.02/hr
gateway_instance_type  = "t3.small"    # ~$0.02/hr
rds_instance_class     = "db.t3.micro" # ~$0.02/hr
# Total: ~$0.46/hr ($11/day)
```

### Production
```hcl
# In terraform.tfvars
webui_instance_type    = "t3.xlarge"   # ~$0.17/hr
gateway_instance_type  = "t3.xlarge"   # ~$0.17/hr
rds_instance_class     = "db.m5.large" # ~$0.19/hr
# Total: ~$0.93/hr ($22/day)
```

**Always destroy when not in use!**

---

## 🔄 Rebuild from Scratch

Minimal steps to rebuild on a new machine:

```bash
# 1. Clone repo (or have the 6 required files)
git clone <repo>
cd ai-portal

# 2. Get secrets from SSM
aws-vault exec personal -- aws ssm get-parameter \
  --name "/com/forora/ai-portal/terraform.tfvars" \
  --with-decryption \
  --region eu-west-2 \
  --query 'Parameter.Value' \
  --output text > terraform.tfvars

# 3. Deploy
terraform init  # Gets state from S3
terraform apply

# 4. Create user & access
# (See Quick Start section above)
```

**That's it!** State syncs from S3, secrets from SSM.

---

## 📋 Checklist Before Teardown

- [ ] terraform.tfvars backed up in AWS SSM ✅
- [ ] terraform.tfstate in S3 backend ✅
- [ ] All `.tf` files committed to git ✅
- [ ] userdata scripts committed to git ✅
- [ ] Route53 hosted zone exists ✅
- [ ] Bedrock model access enabled ✅

If all checked, you can safely `terraform destroy` and rebuild anytime!

---

## 🛡️ Security Best Practices

1. **Never commit secrets** - `.gitignore` protects terraform.tfvars
2. **Restrict network access** - Set `allowed_cidr_blocks` to your IP
3. **Strong passwords** - 16+ characters, generated
4. **MFA on AWS account** - Protect your AWS credentials
5. **Regular updates** - Update Open WebUI image, patch EC2 instances
6. **Monitor costs** - Set up AWS Budgets
7. **Backup strategy** - RDS automated backups (7-day retention)

---

## 📊 Langfuse LLM Observability (v3)

### Overview

Langfuse v3 provides comprehensive observability for all LLM interactions in Open WebUI, including **token usage tracking and cost analytics**. Every conversation is automatically traced and visible in the Langfuse dashboard.

**URL:** https://langfuse.forora.com (or your configured subdomain)

### What's Automated

The entire Langfuse integration is **fully automated** during deployment:

1. **Langfuse Server v3** - Deployed with Docker, ClickHouse, Redis, and MinIO
2. **PostgreSQL** - Shared RDS database for metadata
3. **ClickHouse** - Analytics database for traces and observations
4. **MinIO** - S3-compatible object storage for events and media
5. **Keycloak SSO** - Native Keycloak authentication (same AD credentials as Open WebUI)
6. **Organization & Project** - Auto-created via headless initialization
7. **API Keys** - Pre-generated and configured in Open WebUI pipeline
8. **Tracing Pipeline** - Pre-configured filter sends all LLM calls to Langfuse with token counts

### Key Version Requirements

| Component | Version | Notes |
|-----------|---------|-------|
| **Langfuse Server** | `3.x` | V3 with ClickHouse for analytics |
| **Langfuse Worker** | `3.x` | Background job processing |
| **Langfuse Python SDK** | `>=3.0.0` | V3 SDK with span-based API |
| **ClickHouse** | `latest` | Analytics database |
| **Redis** | `7` | Cache and queue |
| **MinIO** | `latest` | S3-compatible storage |

### Architecture

```
User → Open WebUI → Pipelines Filter → Langfuse API
                         ↓
                   langfuse>=3.0.0
                         ↓
              Langfuse Server (v3)
                    ↓      ↓      ↓
              PostgreSQL  ClickHouse  MinIO
                  (RDS)    (traces)   (events)
```

### Configuration Files

All configuration files are in the `config/` directory:

```
config/
├── langfuse/
│   ├── docker-compose.yml     # Langfuse v3 with all dependencies
│   └── .env.example           # Environment variable template
├── open-webui/
│   ├── docker-compose.yml     # Open WebUI with pipelines + OTEL
│   └── otel-collector-config.yaml  # OTEL collector config
└── pipelines/
    └── langfuse_filter.py     # Langfuse v3 filter pipeline
```

### Langfuse Server Configuration

**Docker Compose Services:**
- `langfuse-web` - Main application (port 3000)
- `langfuse-worker` - Background job processing
- `clickhouse` - Analytics database
- `redis` - Cache and queue
- `minio` - Object storage

**Key Environment Variables:**
```bash
# Database
DATABASE_URL=postgresql://user:pass@host:5432/langfuse?sslmode=require

# ClickHouse
CLICKHOUSE_URL=http://clickhouse:8123
CLICKHOUSE_PASSWORD=<generated>

# Redis
REDIS_HOST=redis
REDIS_AUTH=<generated>

# MinIO/S3
LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT=http://minio:9000
LANGFUSE_S3_EVENT_UPLOAD_BUCKET=langfuse

# Keycloak SSO
AUTH_KEYCLOAK_CLIENT_ID=langfuse
AUTH_KEYCLOAK_ISSUER=https://auth.forora.com/realms/aiportal

# Headless initialization
LANGFUSE_INIT_PROJECT_PUBLIC_KEY=lf_pk_aiportal_openwebui
LANGFUSE_INIT_PROJECT_SECRET_KEY=lf_sk_aiportal_openwebui_secret
```

### Open WebUI Pipeline Filter

The filter is located at: `config/pipelines/langfuse_filter.py`

**Critical Configuration in Valves class:**
```python
class Valves(BaseModel):
    pipelines: List[str] = ["*"]  # MUST be ["*"] not [] for filter to apply
    priority: int = 0
    secret_key: str
    public_key: str
    host: str
```

**IMPORTANT:** The `pipelines` class default MUST be `["*"]` for the filter to be invoked. An empty list `[]` will cause the filter to never be called.

### What Gets Traced

Each conversation trace includes:
- **User ID** - Who made the request
- **Email** - User's email address
- **Model** - Which Bedrock model was used
- **Input** - User's message
- **Output** - LLM response
- **Token Usage** - Input and output token counts
- **Duration** - Response time
- **Chat ID** - Conversation identifier
- **Cost** - Estimated cost based on token usage

### Accessing Langfuse

1. Go to https://langfuse.forora.com
2. Click **"Keycloak"** button to login via SSO
3. Use your AD credentials (same as Open WebUI)
4. Navigate to **Traces** to see all LLM interactions
5. View **Analytics** for token usage and cost dashboards

### Troubleshooting

**No traces appearing:**
```bash
# Check pipeline logs
ssh ec2-user@$(terraform output -raw open_webui_public_ip)
sudo docker logs pipelines 2>&1 | grep -i langfuse

# Should see:
# [DEBUG] Langfuse Filter INLET called
# [DEBUG] Langfuse Filter OUTLET called
# [DEBUG] LLM generation completed for chat_id: xxx
```

**Filter not being invoked:**
```bash
# Check the Valves class default - MUST have pipelines: ["*"]
# If empty [], the filter will never be called!
# Fix: Edit config/pipelines/langfuse_filter.py line 31:
#   pipelines: List[str] = ["*"]  # NOT []

# After fixing, restart pipelines container
sudo docker-compose restart pipelines
```

**Check Langfuse server logs:**
```bash
ssh ec2-user@$(terraform output -raw langfuse_public_ip)
sudo docker logs langfuse-web 2>&1 | tail -50
sudo docker logs langfuse-worker 2>&1 | tail -50
```

### Lessons Learned (Updated for v3)

1. **Langfuse V3 requires ClickHouse** - PostgreSQL alone is no longer sufficient for v3
2. **Pipelines Valves class default matters** - The `pipelines` field must have `["*"]` as the CLASS default, not just in `__init__`
3. **V3 SDK uses span-based API** - `start_span()`, `start_generation()` instead of v2's `trace()`
4. **Flush after each trace** - Call `langfuse.flush()` in outlet to ensure traces are sent
5. **MinIO required for events** - Langfuse v3 stores event data in S3-compatible storage

---

## 🤖 Client Integrations

### Aider (AI Pair Programmer)

[Aider](https://aider.chat) can connect to the AI Portal to use Bedrock models via the OpenAI-compatible API.

**Prerequisites:**
1. Get your API key from Open WebUI: Settings → Account → API Keys → Create new key
2. Create `~/.aider.model.settings.yml` with the following content:

```yaml
- name: "openai/anthropic.claude-3-7-sonnet-20250219-v1:0"
  use_system_prompt: false
```

**Usage:**

```bash
aider --no-stream \
  --model openai/anthropic.claude-3-7-sonnet-20250219-v1:0 \
  --openai-api-base https://portal.openwebui.demos.apps.equal.expert/api \
  --openai-api-key <YOUR_API_KEY>
```

Replace `<YOUR_API_KEY>` with your actual API key from Open WebUI.

**⚠️ Known Issue: Streaming Not Working**

Currently, streaming responses do not work correctly with Aider (requires `--no-stream` flag). This needs investigation:

- **Symptom:** Streaming mode hangs or produces incomplete responses
- **Workaround:** Use `--no-stream` flag
- **TODO:** Investigate whether this is a Bedrock Gateway issue, Open WebUI API compatibility issue, or Aider-specific behaviour with the OpenAI-compatible endpoint

---

## 📚 Additional Resources

- **Keycloak Setup Guide**: See [KEYCLOAK_SETUP.md](KEYCLOAK_SETUP.md) for detailed Keycloak configuration
- **Terraform**: https://www.terraform.io/docs
- **AWS Bedrock**: https://docs.aws.amazon.com/bedrock/
- **Open WebUI**: https://github.com/open-webui/open-webui
- **Keycloak**: https://www.keycloak.org/documentation
- **AWS Directory Service**: https://docs.aws.amazon.com/directoryservice/

---

## 📁 Reference Configuration Files

The `config/` directory contains reference configurations that can be used for manual deployment or as templates:

```
config/
├── langfuse/
│   ├── docker-compose.yml      # Langfuse v3 with ClickHouse, Redis, MinIO
│   └── .env.example            # Environment variable template
├── open-webui/
│   ├── docker-compose.yml      # Open WebUI with pipelines + OTEL collector
│   └── otel-collector-config.yaml   # OTEL collector for Langfuse
└── pipelines/
    ├── langfuse_filter.py      # Langfuse v3 filter (token usage tracking)
    └── turn_limit_filter.py    # Turn limit filter (user + admin roles)
```

These are **reference files only** - the actual deployment uses the embedded configurations in `userdata_*.sh` scripts.

---

**Version:** 4.0
**Last Updated:** 2025-12-03
**Terraform:** >= 1.0
**AWS Provider:** ~> 5.0
**Open WebUI:** ghcr.io/open-webui/open-webui:main
**Keycloak:** quay.io/keycloak/keycloak:26.0
**Langfuse Server:** langfuse/langfuse:3 (with ClickHouse, Redis, MinIO)
**Langfuse SDK:** langfuse>=3.0.0
**Pipeline Filters:** Detoxify, LLM-Guard, Turn Limit, Langfuse (all with `pipelines: ["*"]`)
**WebSocket:** Disabled (`ENABLE_WEBSOCKET_SUPPORT=false`)
**Authentication:** Keycloak SSO with OIDC + LDAP federation to Active Directory
**Observability:** Langfuse v3 with token usage tracking, cost analytics, and auto-provisioned organization/project/API keys
