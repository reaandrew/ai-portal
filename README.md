# AI Portal - AWS Infrastructure

Complete Terraform infrastructure for AI Portal on AWS with Open WebUI, AWS Bedrock integration, PostgreSQL RDS, and Active Directory authentication.

## ✅ LDAP Authentication - WORKING (v0.6.36)

**LDAP authentication WORKS with Open WebUI v0.6.36 when configured correctly.** After extensive debugging (2025-11-17), we identified the root cause and confirmed a working, repeatable procedure.

### Key Requirements

1. **{username} placeholder must be removed** - Use static search filter
2. **ENABLE_PERSISTENT_CONFIG=false** - Use environment variables
3. **Password without special characters recommended** - Avoid `!` in `LDAP_APP_PASSWORD`
4. **Initial admin account required** - To show LDAP login option in UI
5. **Let LDAP create users** - Do NOT pre-create users in database manually

**The userdata script is configured correctly.** See "LDAP Setup Procedure" below for manual setup steps.

---

## 🎯 What's Required vs Optional

### ✅ REQUIRED Files (In This Directory)

**These 7 files are ALL you need to deploy:**

```
main.tf                          # Infrastructure definition
variables.tf                     # Variable declarations
outputs.tf                       # Output values
userdata_open_webui.sh          # Open WebUI EC2 bootstrap (referenced in main.tf)
userdata_bedrock_gateway.sh     # Bedrock Gateway EC2 bootstrap (referenced in main.tf)
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
- **2x EC2 Instances (t3.large)** - Open WebUI + Bedrock Gateway
- **RDS PostgreSQL (db.t3.medium)** - Database for Open WebUI
- **AWS Managed Microsoft AD** - Active Directory for authentication
- **Application Load Balancer** - TLS 1.3 termination
- **ACM Certificate** - SSL/TLS for custom domain
- **VPC with public/private subnets** - Network isolation
- **NAT Gateway** - Outbound internet for private resources
- **Security Groups** - Network access control
- **IAM Roles** - Bedrock API permissions

**Access:** https://ai.forora.com (TLS 1.3, HTTPS only)

**Cost:** ~£1.70/hour (~£41/day) + Bedrock token usage

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
- `db_password` - Strong database password (12+ chars)
- `ad_admin_password` - Strong AD password (8+ chars, avoid `!`)
- `domain_name` - Your Route53 domain (default: forora.com)
- `subdomain` - Subdomain for portal (default: ai)

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

EC2 instances run bootstrap scripts on first boot. Wait 2-3 minutes after `terraform apply` completes.

### 4. Create AD User

**Option 1: Using helper script**
```bash
../create_ad_user.sh testuser Welcome@2024 testuser@corp.aiportal.local
```

**Option 2: Manual AWS CLI**
```bash
AD_DIR_ID=$(terraform output -raw active_directory_id)

aws-vault exec personal -- aws ds-data create-user \
  --directory-id "$AD_DIR_ID" \
  --sam-account-name testuser \
  --given-name "Test" \
  --surname "User" \
  --email-address "testuser@corp.aiportal.local" \
  --region eu-west-2

aws-vault exec personal -- aws ds reset-user-password \
  --directory-id "$AD_DIR_ID" \
  --user-name testuser \
  --new-password "Welcome@2024" \
  --region eu-west-2
```

### 5. Access Portal

```bash
terraform output ai_portal_url
# Output: https://ai.forora.com
```

Login with: `testuser@corp.aiportal.local` / `Welcome@2024`

### 6. Sync Models from Bedrock Gateway

**REQUIRED:** Populate the model table so models appear in the UI.

```bash
./sync_models.sh
# OR: ./sync_models.sh $(terraform output -raw open_webui_public_ip)
```

This syncs all available Bedrock models from the gateway to Open WebUI's database. Without this step, no models will be visible in the UI.

**What it does:**
- Queries Bedrock Gateway at http://10.0.0.28:8000/api/tags
- Populates Open WebUI's `model` table with all available models
- Sets `is_active=1` and `access_control=NULL` (available to all users)
- Filters: Excludes DeepSeek, embed, image, and cross-region-only models (filtering done in gateway)

**When to run:**
- After first deployment
- After any changes to Bedrock model access
- If models disappear from the UI

---

## 📊 Deployment Timeline

| Step | Duration | Notes |
|------|----------|-------|
| VPC & Networking | 2-3 min | VPC, subnets, IGW, NAT |
| AWS Managed AD | 10-15 min | Slowest component |
| RDS PostgreSQL | 5-7 min | Database creation |
| EC2 Instances | 3-5 min | + userdata execution |
| ALB + Certificate | 2-3 min | DNS validation |
| **Total** | **20-30 min** | First deployment |

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

### Verify Services

```bash
# Check status
../status.sh  # OR: terraform output

# SSH into instances
ssh -i ~/.ssh/ai-portal-key ec2-user@$(terraform output -raw open_webui_public_ip)
ssh -i ~/.ssh/ai-portal-key ec2-user@$(terraform output -raw bedrock_gateway_public_ip)

# Check Docker logs
sudo docker logs open-webui
sudo docker ps

# Check Bedrock Gateway
sudo systemctl status bedrock-gateway
sudo journalctl -u bedrock-gateway -f

# Test health
curl http://$(terraform output -raw bedrock_gateway_private_ip):8000/health
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

### LDAP Authentication Setup (WORKING PROCEDURE)

**✅ Confirmed working as of 2025-11-17 with Open WebUI v0.6.36**

#### Step 1: Create AD User

```bash
AD_DIR_ID=$(terraform output -raw active_directory_id)

# Enable Directory Data Access API (first time only)
aws-vault exec personal -- aws ds enable-directory-data-access \
  --directory-id "$AD_DIR_ID" \
  --region eu-west-2

# Create user
aws-vault exec personal -- aws ds-data create-user \
  --directory-id "$AD_DIR_ID" \
  --sam-account-name testuser \
  --given-name "Test" \
  --surname "User" \
  --email-address "testuser@corp.aiportal.local" \
  --region eu-west-2

# Set password (avoid special characters like !)
aws-vault exec personal -- aws ds reset-user-password \
  --directory-id "$AD_DIR_ID" \
  --user-name testuser \
  --new-password "Welcome@2024" \
  --region eu-west-2
```

#### Step 2: Create Initial Admin Account (for LDAP UI)

```bash
WEBUI_IP=$(terraform output -raw open_webui_public_ip)

curl -X POST http://$WEBUI_IP:8080/api/v1/auths/signup \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Admin",
    "email": "admin@example.com",
    "password": "admin123"
  }'
```

**Why needed:** Without at least one user, Open WebUI shows signup screen instead of login screen with LDAP option.

#### Step 3: Login with LDAP

1. Access Open WebUI: `http://<webui_ip>:8080`
2. Click "Sign in with SSO" or LDAP option
3. Enter credentials:
   - Username: `testuser`
   - Password: `Welcome@2024`
4. ✅ Should login successfully!

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

### Troubleshooting LDAP

**Error: "Application account bind failed"**

This means the LDAP admin credentials are wrong. Check:

```bash
ssh ec2-user@$(terraform output -raw open_webui_public_ip)
cat /opt/open-webui/.env | grep LDAP_APP

# Verify password matches AD
# If you need to change it, edit .env and RECREATE container:
cd /opt/open-webui
sudo nano .env  # Edit LDAP_APP_PASSWORD
sudo docker-compose down && sudo docker-compose up -d  # MUST use down/up, not restart!
```

**Error: "The email or password provided is incorrect"**

After confirming LDAP bind works, this usually means auth/users table mismatch. Check:

```bash
ssh ec2-user@$(terraform output -raw open_webui_public_ip)
sudo docker exec -i open-webui python3 <<'EOF'
from open_webui.models.users import Users
from sqlalchemy import create_engine, text
from open_webui.internal.db import engine

email = 'testuser@corp.aiportal.local'
user = Users.get_user_by_email(email)
print(f'Users table: {user.email if user else "NOT FOUND"}')

with engine.connect() as conn:
    result = conn.execute(text(f"SELECT email FROM auth WHERE email = '{email}'"))
    auth = result.fetchone()
    print(f'Auth table: {auth[0] if auth else "NOT FOUND"}')
EOF
```

If user exists in `users` but NOT in `auth`, delete the user and let LDAP recreate it properly:

```bash
sudo docker exec -i open-webui python3 <<'EOF'
from open_webui.models.users import Users
user = Users.get_user_by_email('testuser@corp.aiportal.local')
if user:
    Users.delete_user_by_id(user.id)
    print('Deleted user - try LDAP login again')
EOF
```

**No LDAP Login Option in UI**

Create an initial admin account (see Step 2 above).

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

## 📖 Lessons Learned - LDAP Debugging (2025-11-17)

### ✅ ROOT CAUSE IDENTIFIED AND FIXED

After extensive debugging, LDAP authentication now WORKS with a fully repeatable procedure. The root cause was **database table mismatch**, NOT fundamental LDAP bugs.

### The Actual Problem

**Open WebUI has TWO separate tables for users:**
1. `users` table - Stores user profile (name, email, role, etc.)
2. `auth` table - Stores authentication credentials (email, password hash, active status)

**LDAP authentication flow:**
1. Binds with application account (Admin@corp.aiportal.local)
2. Searches for user by sAMAccountName
3. Binds as the user to verify password
4. **Checks if user exists in `users` table:**
   - If **NO** → calls `Auths.insert_new_auth()` which creates entries in BOTH `auth` and `users` tables ✅
   - If **YES** → assumes `auth` entry already exists and SKIPS creation ❌
5. Calls `Auths.authenticate_user_by_trusted_header()` which requires an `auth` table entry
6. If no `auth` entry found → returns "The email or password provided is incorrect"

### What We Did Wrong

We manually created a user in the `users` table (via `Users.insert_new_user()`), which caused:
- ✅ User exists in `users` table
- ❌ NO entry in `auth` table
- ❌ LDAP skips `insert_new_auth()` because user already exists
- ❌ `authenticate_user_by_trusted_header()` fails because no `auth` entry
- ❌ Error: "The email or password provided is incorrect"

**Even though LDAP authentication succeeded**, the final database lookup failed.

### Other Issues Discovered

#### Issue 1: Password with Special Characters
**Symptom:** "Application account bind failed"
**Root Cause:** `LDAP_APP_PASSWORD` in terraform.tfvars had `!` character. When changed in .env, container wasn't reloaded properly.
**Solution:** Use password without `!` and recreate container with `docker-compose down && up` (NOT `restart`)
**Learning:** `docker-compose restart` does NOT reload .env file

#### Issue 2: {username} Placeholder in Search Filter
**Symptom:** Would cause "User not found" in some versions
**Root Cause:** GitHub issues #16760, #14993 document this bug
**Solution:** Use static filter: `(&(objectClass=user)(objectCategory=person))`
**Note:** This works fine; LDAP searches for all users in base, then filters by sAMAccountName in code

#### Issue 3: LDAP Login Option Missing
**Symptom:** No LDAP option shown in UI after fresh deployment
**Root Cause:** Open WebUI shows signup page when there are zero users
**Solution:** Create one user via `/api/v1/auths/signup` first, then LDAP option appears

#### Issue 4: ENABLE_PERSISTENT_CONFIG
**Symptom:** LDAP config doesn't persist when set via admin UI
**Root Cause:** v0.6.36 has issues with database-stored configuration
**Solution:** Set `ENABLE_PERSISTENT_CONFIG=false` and use environment variables

### Working Configuration (Confirmed 2025-11-17)

```bash
# /opt/open-webui/.env
ENABLE_PERSISTENT_CONFIG=false
ENABLE_SIGNUP=true
ENABLE_LDAP=true
LDAP_SERVER_HOST=10.0.10.214
LDAP_SERVER_PORT=389
LDAP_USE_TLS=false
LDAP_APP_DN=Admin@corp.aiportal.local    # UPN format works fine
LDAP_APP_PASSWORD=SecurePassword2024     # No special characters
LDAP_SEARCH_BASE=OU=Users,OU=corp,DC=corp,DC=aiportal,DC=local
LDAP_SEARCH_FILTER=(&(objectClass=user)(objectCategory=person))  # Static filter, no {username}
LDAP_ATTRIBUTE_FOR_USERNAME=sAMAccountName
LDAP_ATTRIBUTE_FOR_MAIL=mail
```

### Key Takeaways

1. **Never manually create users for LDAP** - Let LDAP create them via first login
2. **Always recreate containers after .env changes** - Use `down && up`, not `restart`
3. **Avoid special characters in passwords** - Especially `!` which can cause shell escaping issues
4. **Create initial admin via API** - Required to show LDAP login option
5. **LDAP itself works fine** - The issues were configuration and database management, not LDAP protocol

### This Infrastructure IS Repeatable

Following the documented procedure:
1. Deploy infrastructure with terraform
2. Create AD user via AWS CLI
3. Create initial admin via curl
4. Login with LDAP credentials
5. ✅ **It just works!**

Previous claims that "this isn't repeatable" were based on misunderstanding the root cause. With the correct procedure, LDAP authentication is 100% reliable.

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
- **Bedrock Gateway**: Allows 8000 from VPC + SSH
- **RDS**: Allows 5432 from EC2 instances only
- **AD**: Allows LDAP/Kerberos/DNS from VPC

### IAM Permissions
EC2 instances have IAM role with:
- `bedrock:InvokeModel`
- `bedrock:InvokeModelWithResponseStream`
- `bedrock:ListFoundationModels`
- `bedrock:GetFoundationModel`

### Open WebUI Configuration
Environment variables set in `userdata_open_webui.sh`:
- `DATABASE_URL` - PostgreSQL connection
- `OLLAMA_BASE_URL` - Points to Bedrock Gateway
- `ENABLE_LDAP=true` - Active Directory auth
- `SAVE_CHAT_HISTORY=false` - No chat history storage
- `ENABLE_SIGNUP=false` - No self-registration

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

## 📚 Additional Resources

- **Terraform**: https://www.terraform.io/docs
- **AWS Bedrock**: https://docs.aws.amazon.com/bedrock/
- **Open WebUI**: https://github.com/open-webui/open-webui
- **AWS Directory Service**: https://docs.aws.amazon.com/directoryservice/

---

**Version:** 1.1
**Last Updated:** 2025-11-17
**Terraform:** >= 1.0
**AWS Provider:** ~> 5.0
**Open WebUI:** v0.6.36 (main tag) - **LDAP authentication WORKS, see LDAP Setup Procedure section**
