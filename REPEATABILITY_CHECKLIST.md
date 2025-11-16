# AI Portal - Repeatability Checklist

## ✅ Quick Re-provisioning Checklist

Use this checklist before tearing down to ensure you can rebuild:

### 📁 Files to Preserve

- [ ] `terraform.tfvars` - **STORED IN AWS SSM**: `/com/forora/ai-portal/terraform.tfvars`
- [ ] `terraform.tfstate` - **STORED IN S3**: `ai-portal-terraform-state-276447169330`
- [ ] `main.tf` - Infrastructure definition
- [ ] `variables.tf` - Variable definitions
- [ ] `outputs.tf` - Output definitions
- [ ] `userdata_open_webui.sh` - Bootstrap script
- [ ] `userdata_bedrock_gateway.sh` - Bootstrap script
- [ ] All `*.sh` helper scripts
- [ ] SSH private key (`~/.ssh/ai-portal-key`)

### 🔐 Secrets to Document

- [ ] Database password (from `terraform.tfvars`)
- [ ] AD admin password (from `terraform.tfvars`)
- [ ] AWS account ID
- [ ] SSH key pair location

### 🌐 External Requirements

- [ ] Route53 hosted zone exists for domain
- [ ] Bedrock model access enabled in AWS Console
- [ ] AWS CLI configured
- [ ] Correct IAM permissions

### 📝 Configuration Values

- [ ] Domain name: `________________`
- [ ] Subdomain: `________________`
- [ ] AWS Region: `________________`
- [ ] VPC CIDR: `________________`

### 🧪 Test After Rebuild

- [ ] Can access HTTPS URL
- [ ] Certificate is valid (TLS 1.3)
- [ ] Can login with AD credentials
- [ ] Can select Bedrock models
- [ ] Can send test message
- [ ] Database connected
- [ ] LDAP authentication works

---

## 🚨 What You MUST Have to Rebuild

### Absolute Minimum

1. **terraform.tfvars** with:
   - Database password
   - AD password
   - SSH public key
   - Domain configuration

2. **All `.tf` files**:
   - main.tf
   - variables.tf
   - outputs.tf

3. **Userdata scripts**:
   - userdata_open_webui.sh
   - userdata_bedrock_gateway.sh

4. **AWS Prerequisites**:
   - Route53 hosted zone
   - Bedrock access enabled
   - Valid AWS credentials

### Nice to Have

- Helper scripts (deploy.sh, destroy.sh, etc.)
- PROVISIONING.md documentation
- terraform.tfstate backup

---

## 🔄 Rebuild Process (Quick)

```bash
# 1. Verify AWS access
aws sts get-caller-identity

# 2. Verify Bedrock access
aws bedrock list-foundation-models --region eu-west-2

# 3. Initialize Terraform
terraform init

# 4. Plan
terraform plan

# 5. Apply
terraform apply

# 6. Wait 20-30 minutes

# 7. Verify outputs
terraform output

# 8. Test access
curl -k https://$(terraform output -raw ai_portal_url)
```

---

## ⚠️ Common Gotchas

1. **Terraform state lost** → Can't manage existing infrastructure
2. **Wrong passwords in tfvars** → Database/AD connection fails
3. **Bedrock access not enabled** → Models don't work
4. **Route53 zone doesn't exist** → DNS/certificate fails
5. **SSH key lost** → Can't access instances

---

## 💾 Backup Strategy

### Before Teardown

```bash
# Backup all critical files
mkdir -p ~/ai-portal-backup-$(date +%Y%m%d)
cp terraform.tfvars ~/ai-portal-backup-$(date +%Y%m%d)/
cp terraform.tfstate ~/ai-portal-backup-$(date +%Y%m%d)/
cp *.tf ~/ai-portal-backup-$(date +%Y%m%d)/
cp *.sh ~/ai-portal-backup-$(date +%Y%m%d)/
cp ~/.ssh/ai-portal-key* ~/ai-portal-backup-$(date +%Y%m%d)/

# Encrypt the backup
tar czf - ~/ai-portal-backup-$(date +%Y%m%d) | \
  gpg --symmetric --cipher-algo AES256 > ai-portal-backup-$(date +%Y%m%d).tar.gz.gpg

# Store securely (cloud storage, password manager, etc.)
```

### Remote Backend (Recommended)

Instead of manual backups, use S3 backend:

```bash
# Create S3 bucket
aws s3api create-bucket \
  --bucket ai-portal-terraform-state-$(aws sts get-caller-identity --query Account --output text) \
  --region eu-west-2 \
  --create-bucket-configuration LocationConstraint=eu-west-2

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket ai-portal-terraform-state-$(aws sts get-caller-identity --query Account --output text) \
  --versioning-configuration Status=Enabled
```

See [PROVISIONING.md](PROVISIONING.md#terraform-backend) for full backend setup.

---

## 📋 Infrastructure Inventory

### What Gets Created

| Resource | Type | Critical for Rebuild |
|----------|------|---------------------|
| VPC | Network | Auto-created |
| Subnets (4) | Network | Auto-created |
| Internet Gateway | Network | Auto-created |
| NAT Gateway | Network | Auto-created |
| Route Tables | Network | Auto-created |
| Security Groups (5) | Network | Defined in main.tf |
| EC2 - Open WebUI | Compute | Defined in main.tf |
| EC2 - Bedrock Gateway | Compute | Defined in main.tf |
| RDS PostgreSQL | Database | Defined in main.tf |
| AWS Managed AD | Directory | Defined in main.tf |
| IAM Role | Security | Defined in main.tf |
| IAM Instance Profile | Security | Defined in main.tf |
| ACM Certificate | Security | Defined in main.tf |
| Application Load Balancer | Network | Defined in main.tf |
| Target Group | Network | Defined in main.tf |
| Route53 A Record | DNS | Defined in main.tf |

### What Survives Destroy

- Route53 Hosted Zone (not managed by Terraform)
- S3 Backend bucket (if configured)
- DynamoDB lock table (if configured)

---

## 🎯 Re-provisioning Scenarios

### Scenario 1: Lost terraform.tfstate

**Impact**: SEVERE - Can't manage infrastructure with Terraform

**Solutions**:
1. Use remote backend (prevents this)
2. Import existing resources manually (very tedious)
3. Destroy manually via Console + rebuild

### Scenario 2: Lost terraform.tfvars

**Impact**: HIGH - Need to recreate passwords/config

**Recovery**:
- Passwords are in AWS (RDS, AD) but you can't retrieve them
- Must destroy and rebuild with new passwords
- Or manually update passwords in AWS and tfvars

### Scenario 3: Lost Terraform files

**Impact**: MEDIUM - Can recreate from git/backup

**Recovery**:
- Pull from git repository
- Restore from backup

### Scenario 4: Forgot to enable Bedrock

**Impact**: LOW - Can enable post-deployment

**Recovery**:
```bash
# Enable via Console: AWS > Bedrock > Model access
# Then restart gateway:
ssh ec2-user@<gateway-ip> 'sudo systemctl restart bedrock-gateway'
```

---

## 🔒 Security Considerations

### Secrets Storage

**Current**: terraform.tfvars (local file)

**Better**: AWS Secrets Manager

Example migration:
```hcl
# Store in Secrets Manager
resource "aws_secretsmanager_secret" "db_password" {
  name = "ai-portal-db-password"
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password
}

# Reference in RDS
resource "aws_db_instance" "postgres" {
  password = data.aws_secretsmanager_secret_version.db_password.secret_string
  # ...
}
```

---

## 📊 Cost Tracking

| Component | Hourly | Daily | Monthly |
|-----------|--------|-------|---------|
| EC2 (2x t3.large) | $0.17 | $4.08 | $122 |
| RDS (db.t3.medium) | $0.07 | $1.68 | $50 |
| AWS Managed AD | $0.40 | $9.60 | $288 |
| NAT Gateway | $0.05 | $1.20 | $36 |
| ALB | $0.03 | $0.72 | $22 |
| Storage | $0.01 | $0.24 | $7 |
| **Total Infrastructure** | **$0.73** | **$17.52** | **$525** |
| Bedrock (variable) | ~$1.00 | ~$24 | ~$720 |
| **TOTAL** | **~$1.73** | **~$41** | **~$1,245** |

**Destroy when not in use to avoid charges!**

---

This checklist ensures you have everything needed to reliably rebuild the AI Portal infrastructure.
