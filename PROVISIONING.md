# AI Portal - Complete Provisioning Guide

This document contains ALL information required to repeatably provision the AI Portal infrastructure from scratch.

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Critical Files](#critical-files)
3. [Initial Setup](#initial-setup)
4. [Terraform Backend (Optional but Recommended)](#terraform-backend)
5. [Step-by-Step Deployment](#step-by-step-deployment)
6. [Post-Deployment Configuration](#post-deployment-configuration)
7. [Verification](#verification)
8. [Teardown](#teardown)
9. [Re-provisioning Checklist](#re-provisioning-checklist)

---

## Prerequisites

### Required Tools
- **Terraform** >= 1.0 ([Download](https://www.terraform.io/downloads))
- **AWS CLI** >= 2.0 ([Download](https://aws.amazon.com/cli/))
- **Git** (for version control)
- **jq** (for JSON parsing in scripts)
- **ssh** client

### AWS Account Requirements

#### 1. AWS Credentials
```bash
# Configure AWS CLI
aws configure

# Or use AWS SSO/aws-vault
aws-vault exec <profile> -- aws sts get-caller-identity
```

#### 2. Required AWS Permissions

Your IAM user/role must have permissions for:
- **EC2**: Full access (instances, VPC, security groups, key pairs)
- **RDS**: Create and manage PostgreSQL databases
- **Directory Service**: Create and manage Microsoft AD
- **IAM**: Create roles and policies
- **Route53**: Manage DNS records in your hosted zone
- **ACM**: Request and manage SSL certificates
- **ELB**: Create and manage Application Load Balancers
- **Bedrock**: Invoke models and list foundation models

#### 3. Bedrock Model Access

**CRITICAL**: Enable Bedrock model access BEFORE deployment:

```bash
# 1. Go to AWS Console > Bedrock > Model access
# 2. Click "Manage model access"
# 3. Enable the following models:
#    - Anthropic Claude Sonnet 4.5
#    - Anthropic Claude Haiku 4.5
#    - Anthropic Claude 3.7 Sonnet
#    - Anthropic Claude 3 Sonnet
#    - Anthropic Claude 3 Haiku
# 4. Submit request (usually instant approval)

# Verify via CLI:
aws bedrock list-foundation-models \
  --region eu-west-2 \
  --by-provider anthropic \
  --query "modelSummaries[?contains(modelId, 'claude')].modelId"
```

#### 4. Route53 Hosted Zone

You MUST have a Route53 hosted zone for your domain:

```bash
# Check if hosted zone exists
aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='forora.com.'].{Name:Name,Id:Id}"

# If not, create one:
aws route53 create-hosted-zone \
  --name forora.com \
  --caller-reference $(date +%s)
```

**Important**: Update your domain's nameservers to point to the Route53 name servers.

---

## Critical Files

### Files Required for Provisioning

| File | Required | Purpose | Contains Secrets |
|------|----------|---------|------------------|
| `main.tf` | ✅ YES | Infrastructure definition | No |
| `variables.tf` | ✅ YES | Variable definitions | No |
| `outputs.tf` | ✅ YES | Output values | No |
| `terraform.tfvars` | ✅ YES | Variable values | **YES** |
| `userdata_open_webui.sh` | ✅ YES | WebUI bootstrap | No |
| `userdata_bedrock_gateway.sh` | ✅ YES | Gateway bootstrap | No |
| `deploy.sh` | ⚪ Optional | Deployment helper | No |
| `destroy.sh` | ⚪ Optional | Teardown helper | No |
| `status.sh` | ⚪ Optional | Status checker | No |
| `create_ad_user.sh` | ⚪ Optional | User creation helper | No |
| `set_ad_admin.sh` | ⚪ Optional | Admin role helper | No |

### Files to NEVER Commit

Add these to `.gitignore`:
```
# Terraform state (contains secrets!)
*.tfstate
*.tfstate.*
*.tfstate.backup

# Variable files (contains passwords!)
terraform.tfvars
*.auto.tfvars

# Plans
tfplan*

# SSH keys
*.pem
*.key

# Backup files
*.backup
*.bak
```

---

## Terraform Backend (Optional but Recommended)

**Current State**: Local state file (`terraform.tfstate`)

**Problem**: If you lose the state file, you lose track of your infrastructure!

### Option 1: S3 Backend (Recommended)

Create an S3 bucket for state:
```bash
# Create S3 bucket for state
aws s3api create-bucket \
  --bucket ai-portal-terraform-state-YOUR-ACCOUNT-ID \
  --region eu-west-2 \
  --create-bucket-configuration LocationConstraint=eu-west-2

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket ai-portal-terraform-state-YOUR-ACCOUNT-ID \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket ai-portal-terraform-state-YOUR-ACCOUNT-ID \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name ai-portal-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-2
```

Add to `main.tf` (at the top):
```hcl
terraform {
  backend "s3" {
    bucket         = "ai-portal-terraform-state-YOUR-ACCOUNT-ID"
    key            = "ai-portal/terraform.tfstate"
    region         = "eu-west-2"
    encrypt        = true
    dynamodb_table = "ai-portal-terraform-locks"
  }

  required_version = ">= 1.0"
  # ... rest of terraform block
}
```

Then migrate:
```bash
terraform init -migrate-state
```

### Option 2: Keep Local State (Not Recommended)

If keeping local state:
1. **BACKUP** `terraform.tfstate` after every change
2. Store backup in secure location (encrypted)
3. Never commit to git

---

## Initial Setup

### 1. Clone/Download Repository

```bash
git clone <repository-url>
cd ai-portal
```

### 2. Create SSH Key Pair

```bash
# Generate new key pair
ssh-keygen -t ed25519 -f ~/.ssh/ai-portal-key -C "ai-portal"

# Set permissions
chmod 600 ~/.ssh/ai-portal-key
chmod 644 ~/.ssh/ai-portal-key.pub
```

### 3. Configure Variables

**Option 1: Retrieve from AWS SSM Parameter Store (Recommended)**

The terraform.tfvars file is stored securely in AWS Systems Manager Parameter Store:

```bash
# Retrieve from SSM Parameter Store
aws-vault exec personal -- aws ssm get-parameter \
  --name "/com/forora/ai-portal/terraform.tfvars" \
  --with-decryption \
  --region eu-west-2 \
  --query 'Parameter.Value' \
  --output text > terraform.tfvars
```

**Option 2: Create from scratch**

```bash
# Copy example file
cp terraform.tfvars.example terraform.tfvars

# Edit with your values
nano terraform.tfvars
```

**Required Changes in `terraform.tfvars`:**

```hcl
# 1. SSH Configuration
ssh_public_key = "ssh-ed25519 AAAAC3Nza... your-email@example.com"

# 2. Database Password (STRONG PASSWORD REQUIRED)
db_password = "YOUR_SECURE_DB_PASSWORD_HERE"
# Requirements:
# - At least 12 characters
# - Mix of upper/lowercase, numbers, symbols
# - No common patterns

# 3. Active Directory Password (STRONG PASSWORD REQUIRED)
ad_admin_password = "YOUR_SECURE_AD_PASSWORD_HERE"
# Requirements:
# - At least 8 characters
# - Must contain: uppercase, lowercase, number, special char
# - Cannot contain username or domain name
# - AVOID exclamation marks (!) - LDAP issues

# 4. Domain Configuration (if different from forora.com)
domain_name = "yourdomain.com"
subdomain   = "ai"

# 5. Security (IMPORTANT)
allowed_cidr_blocks = ["YOUR.IP.ADDRESS/32"]
# Get your IP: curl https://api.ipify.org

# 6. Optional: Instance sizing
webui_instance_type    = "t3.large"     # or t3.medium for dev
gateway_instance_type  = "t3.large"     # or t3.medium for dev
rds_instance_class     = "db.t3.medium" # or db.t3.small for dev
```

### 4. Verify Configuration

```bash
# Check AWS access
aws sts get-caller-identity

# Check Bedrock access
aws bedrock list-foundation-models --region eu-west-2

# Check Route53 zone
aws route53 list-hosted-zones
```

---

## Step-by-Step Deployment

### Method 1: Using deploy.sh (Recommended)

```bash
./deploy.sh
```

The script will:
1. Check prerequisites
2. Verify Bedrock access
3. Run `terraform init`
4. Run `terraform plan`
5. Ask for confirmation
6. Run `terraform apply`
7. Display outputs

### Method 2: Manual Terraform

```bash
# 1. Initialize Terraform
terraform init

# 2. Validate configuration
terraform validate

# 3. Plan deployment (review changes)
terraform plan -out=tfplan

# 4. Apply plan
terraform apply tfplan

# 5. View outputs
terraform output
```

**Deployment Timeline:**
- VPC & Networking: 2-3 minutes
- AWS Managed AD: 10-15 minutes (slowest)
- RDS PostgreSQL: 5-7 minutes
- EC2 Instances: 3-5 minutes
- ACM Certificate: 2-3 minutes
- **Total: 20-30 minutes**

---

## Post-Deployment Configuration

### 1. Get Access Information

```bash
# Get all outputs
terraform output

# Specific outputs
terraform output ai_portal_url
terraform output open_webui_public_ip
terraform output rds_endpoint
```

### 2. Wait for Userdata Scripts

The EC2 instances run bootstrap scripts on first boot. Wait 2-3 minutes after deployment.

**Verify Open WebUI:**
```bash
WEBUI_IP=$(terraform output -raw open_webui_public_ip)
ssh -i ~/.ssh/ai-portal-key ec2-user@$WEBUI_IP

# Check Docker status
sudo docker ps
sudo docker logs open-webui
```

**Verify Bedrock Gateway:**
```bash
GATEWAY_IP=$(terraform output -raw bedrock_gateway_public_ip)
ssh -i ~/.ssh/ai-portal-key ec2-user@$GATEWAY_IP

# Check service status
sudo systemctl status bedrock-gateway
sudo journalctl -u bedrock-gateway -n 50
```

### 3. Create Active Directory User

```bash
# Create test user
./create_ad_user.sh testuser Welcome@2024 testuser@corp.aiportal.local

# Or use AWS CLI directly
AD_DIR_ID=$(terraform output -raw active_directory_id)
aws ds-data create-user \
  --directory-id "$AD_DIR_ID" \
  --sam-account-name testuser \
  --given-name "Test" \
  --surname "User" \
  --email-address "testuser@corp.aiportal.local" \
  --region eu-west-2

aws ds reset-user-password \
  --directory-id "$AD_DIR_ID" \
  --user-name testuser \
  --new-password "Welcome@2024" \
  --region eu-west-2
```

### 4. Set User as Admin (Optional)

```bash
# User must login once first, then:
./set_ad_admin.sh testuser@corp.aiportal.local
```

### 5. Access the Portal

```bash
# Get URL
terraform output ai_portal_url

# Output: https://ai.forora.com
```

Login with:
- **Email**: testuser@corp.aiportal.local
- **Password**: Welcome@2024

---

## Verification

### 1. Infrastructure Health Checks

```bash
# Quick status check
./status.sh

# Or manual checks
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=AI-Portal" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress]' \
  --output table

aws rds describe-db-instances \
  --db-instance-identifier ai-portal-postgres \
  --query 'DBInstances[0].[DBInstanceStatus,Endpoint.Address]' \
  --output table

aws ds describe-directories \
  --query 'DirectoryDescriptions[0].[DirectoryId,Stage,DnsIpAddrs]' \
  --output table
```

### 2. Application Health Checks

```bash
# Test Bedrock Gateway
GATEWAY_PRIVATE_IP=$(terraform output -raw bedrock_gateway_private_ip)
ssh -i ~/.ssh/ai-portal-key ec2-user@$WEBUI_IP \
  "curl -s http://${GATEWAY_PRIVATE_IP}:8000/health"

# Expected output: {"status":"healthy","service":"bedrock-gateway","version":"3.0.0"}

# Test model list
ssh -i ~/.ssh/ai-portal-key ec2-user@$WEBUI_IP \
  "curl -s http://${GATEWAY_PRIVATE_IP}:8000/api/tags" | jq '.models[].name'
```

### 3. DNS and TLS Verification

```bash
# Check DNS resolution
dig ai.forora.com

# Check certificate
openssl s_client -connect ai.forora.com:443 -servername ai.forora.com < /dev/null | \
  openssl x509 -noout -text | grep -A2 "Subject:"

# Test HTTPS access
curl -I https://ai.forora.com
```

---

## Teardown

### Using destroy.sh (Recommended)

```bash
./destroy.sh
```

### Manual Terraform Destroy

```bash
# Plan destroy
terraform plan -destroy

# Execute destroy
terraform destroy

# Confirm by typing: yes
```

**What Gets Deleted:**
- All EC2 instances
- RDS database (unless skip_final_snapshot = false)
- AWS Managed AD
- VPC and all networking
- Load balancer
- Route53 A record (NOT the hosted zone)
- ACM certificate
- All security groups and IAM roles

**What Survives:**
- Route53 hosted zone
- S3 backend bucket (if configured)
- DynamoDB lock table (if configured)

### Clean Up Additional Resources

```bash
# Delete EC2 key pair (if created by deploy.sh)
aws ec2 delete-key-pair --key-name ai-portal-key --region eu-west-2
rm -f ~/.ssh/ai-portal-key ~/.ssh/ai-portal-key.pub

# Remove local state (if not using backend)
rm -f terraform.tfstate terraform.tfstate.backup
```

---

## Re-provisioning Checklist

Use this checklist to ensure you have everything needed to rebuild from scratch:

### Pre-Deployment Checklist

- [ ] AWS CLI configured and tested
- [ ] Terraform installed (>= 1.0)
- [ ] All required files present (see [Critical Files](#critical-files))
- [ ] `terraform.tfvars` configured with:
  - [ ] SSH public key
  - [ ] Strong database password
  - [ ] Strong AD password
  - [ ] Correct domain name
  - [ ] Your IP address for security
- [ ] Route53 hosted zone exists for your domain
- [ ] Bedrock model access enabled in AWS Console
- [ ] IAM permissions verified

### Deployment Checklist

- [ ] `terraform init` successful
- [ ] `terraform validate` passes
- [ ] `terraform plan` reviewed (no unexpected changes)
- [ ] `terraform apply` completed (20-30 min)
- [ ] All outputs displayed

### Post-Deployment Checklist

- [ ] Wait 2-3 minutes for userdata scripts
- [ ] Open WebUI Docker container running
- [ ] Bedrock Gateway service running
- [ ] DNS record resolves correctly
- [ ] HTTPS certificate valid
- [ ] Can access https://ai.forora.com
- [ ] Created at least one AD user
- [ ] Can login to Open WebUI with AD credentials
- [ ] Can select Bedrock models in UI
- [ ] Can send test message to Claude

### Backup Checklist

- [ ] `terraform.tfstate` backed up securely
- [ ] `terraform.tfvars` backed up securely (encrypted!)
- [ ] All `.sh` scripts backed up
- [ ] SSH private key backed up securely

---

## External Dependencies

The deployment relies on these external services (possible points of failure):

1. **GitHub** - Docker Compose downloads
   - URL: `https://github.com/docker/compose/releases/latest/download/`
   - Mitigation: Cache locally or use specific version

2. **GitHub Container Registry** - Open WebUI image
   - URL: `ghcr.io/open-webui/open-webui:main`
   - Mitigation: Use specific tag instead of `:main`

3. **PyPI** - Python packages for Bedrock Gateway
   - Packages: fastapi, uvicorn, boto3, pydantic, python-dotenv
   - Mitigation: Create requirements.txt with pinned versions

4. **AWS Services**
   - Bedrock API
   - EC2, RDS, Directory Service
   - Route53, ACM

---

## Troubleshooting Common Issues

### Issue: Terraform apply fails with "InvalidParameterException"

**Cause**: AD password doesn't meet complexity requirements

**Solution**:
```bash
# Ensure password meets requirements:
# - At least 8 characters
# - Contains upper, lower, number, symbol
# - No username/domain in password
# - AVOID exclamation marks (!)
```

### Issue: Cannot access Open WebUI after deployment

**Solution**:
```bash
# 1. Wait 2-3 minutes for userdata to complete
# 2. Check Docker status
ssh -i ~/.ssh/ai-portal-key ec2-user@$(terraform output -raw open_webui_public_ip)
sudo docker ps
sudo docker logs open-webui

# 3. Restart if needed
cd /opt/open-webui && sudo docker-compose restart
```

### Issue: Bedrock models not showing

**Solution**:
```bash
# 1. Verify model access in AWS Console
# 2. Check Gateway logs
ssh -i ~/.ssh/ai-portal-key ec2-user@$(terraform output -raw bedrock_gateway_public_ip)
sudo journalctl -u bedrock-gateway -n 100

# 3. Verify IAM role
aws iam get-role --role-name ai-portal-bedrock-access
```

### Issue: LDAP authentication fails

**Solution**:
```bash
# 1. Verify AD is fully provisioned (can take 20 min)
aws ds describe-directories

# 2. Check AD user exists
aws ds-data describe-user \
  --directory-id $(terraform output -raw active_directory_id) \
  --sam-account-name testuser \
  --region eu-west-2

# 3. Reset password
aws ds reset-user-password \
  --directory-id $(terraform output -raw active_directory_id) \
  --user-name testuser \
  --new-password "NewPassword@2024" \
  --region eu-west-2
```

---

## Cost Optimization

### Development Environment
```hcl
# terraform.tfvars
webui_instance_type    = "t3.small"    # ~$0.02/hr
gateway_instance_type  = "t3.small"    # ~$0.02/hr
rds_instance_class     = "db.t3.micro" # ~$0.02/hr
# Total: ~$0.46/hr ($11/day)
```

### Production Environment
```hcl
# terraform.tfvars
webui_instance_type    = "t3.xlarge"   # ~$0.17/hr
gateway_instance_type  = "t3.xlarge"   # ~$0.17/hr
rds_instance_class     = "db.m5.large" # ~$0.19/hr
# Total: ~$0.93/hr ($22/day)
```

**Always destroy when not in use!**

---

## Security Best Practices

1. **Never commit secrets to git**
   - Use `.gitignore` for `terraform.tfvars`
   - Use AWS Secrets Manager for production

2. **Restrict network access**
   - Set `allowed_cidr_blocks` to your IP only
   - Use VPN for team access

3. **Use strong passwords**
   - 16+ character passwords
   - Generated passwords recommended

4. **Enable MFA**
   - On AWS account
   - On critical IAM users

5. **Regular updates**
   - Update Open WebUI image regularly
   - Patch EC2 instances monthly

6. **Monitor costs**
   - Set up AWS Budgets
   - Use Cost Explorer

7. **Backup strategy**
   - RDS automated backups enabled (7 days)
   - Export important chats manually
   - Backup terraform state

---

## Support and Maintenance

For issues:
1. Check [Troubleshooting](#troubleshooting-common-issues)
2. Review CloudWatch logs
3. Check AWS service health
4. Verify Bedrock model access

For updates:
- Monitor Open WebUI releases
- Update Terraform AWS provider periodically
- Review AWS Bedrock new model availability

---

**Document Version**: 1.0
**Last Updated**: 2025-11-16
**Terraform Version**: >= 1.0
**AWS Provider**: ~> 5.0
