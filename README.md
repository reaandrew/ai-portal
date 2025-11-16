# AI Portal - AWS Infrastructure

Complete Terraform infrastructure for AI Portal on AWS with Open WebUI, AWS Bedrock integration, PostgreSQL RDS, and Active Directory authentication.

## 🎯 What's Required vs Optional

### ✅ REQUIRED Files (In This Directory)

**These 7 files are ALL you need to deploy:**

```
main.tf                          # Infrastructure definition
variables.tf                     # Variable declarations
outputs.tf                       # Output values
userdata_open_webui.sh          # Open WebUI EC2 bootstrap (referenced in main.tf)
userdata_bedrock_gateway.sh     # Bedrock Gateway EC2 bootstrap (referenced in main.tf)
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

### LDAP Authentication Fails

```bash
# Wait for AD to be fully provisioned (can take 20 min)
aws-vault exec personal -- aws ds describe-directories

# Verify user exists
AD_DIR_ID=$(terraform output -raw active_directory_id)
aws-vault exec personal -- aws ds-data describe-user \
  --directory-id "$AD_DIR_ID" \
  --sam-account-name testuser \
  --region eu-west-2

# Reset password
aws-vault exec personal -- aws ds reset-user-password \
  --directory-id "$AD_DIR_ID" \
  --user-name testuser \
  --new-password "NewPassword@2024" \
  --region eu-west-2
```

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

**Version:** 1.0
**Last Updated:** 2025-11-16
**Terraform:** >= 1.0
**AWS Provider:** ~> 5.0
