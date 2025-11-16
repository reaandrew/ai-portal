# AI Portal - AWS Infrastructure with Terraform

This Terraform configuration deploys a complete AI portal infrastructure on AWS, featuring Open WebUI with AWS Bedrock integration, PostgreSQL database, and Microsoft Active Directory.

> **📖 For complete provisioning and repeatability documentation, see [PROVISIONING.md](PROVISIONING.md)**

## Architecture Overview

The infrastructure includes:

- **2x EC2 Instances (t3.large)**
  - Open WebUI server
  - Bedrock Access Gateway
- **RDS PostgreSQL (db.t3.medium)** - Database for Open WebUI
- **AWS Managed Microsoft AD** - Active Directory for authentication
- **VPC with public/private subnets** - Network isolation
- **NAT Gateway** - Outbound internet access for private resources
- **Security Groups** - Fine-grained network access control
- **IAM Roles** - Bedrock API access permissions

## Cost Estimate

Approximate cost for **1 hour** in eu-west-2 (London):

| Component                 | Cost/Hour |
|---------------------------|-----------|
| EC2 (2x t3.large)         | $0.17     |
| RDS (db.t3.medium)        | $0.07     |
| AWS Managed AD            | $0.40     |
| NAT Gateway               | $0.05     |
| Storage (EBS/RDS)         | ~$0.01    |
| **Subtotal (infrastructure)** | **~$0.70** |
| Bedrock (200k in/50k out) | $1.35     |
| **Total (1 hour)**        | **~$2.05** |

**Note:** Bedrock costs scale with token usage. The estimate above assumes moderate usage with Claude 3.5 Sonnet.

## Prerequisites

1. **AWS Account** with appropriate permissions
2. **AWS CLI** configured with credentials
3. **Terraform** >= 1.0 installed
4. **EC2 Key Pair** created in eu-west-2
5. **Bedrock Model Access** - Enable Claude models in AWS Bedrock console

### Enable Bedrock Model Access

Before deploying, enable Claude models in AWS Bedrock:

1. Go to AWS Console > Bedrock > Model access
2. Request access to:
   - Claude 3.5 Sonnet
   - Claude 3 Sonnet
   - Claude 3 Haiku
3. Wait for approval (usually immediate for most models)

## Quick Start

### 1. Create EC2 Key Pair

```bash
# Create a new key pair in eu-west-2
aws ec2 create-key-pair \
  --key-name ai-portal-key \
  --region eu-west-2 \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/ai-portal-key.pem

# Set proper permissions
chmod 400 ~/.ssh/ai-portal-key.pem
```

### 2. Clone and Configure

```bash
# Navigate to the project directory
cd ai-portal

# Copy the example variables file
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with your settings
nano terraform.tfvars
```

### 3. Configure Variables

Edit `terraform.tfvars` and update:

```hcl
# Required changes:
key_name = "ai-portal-key"  # Your EC2 key pair name
db_password = "YourSecurePassword123!"  # Strong password
ad_admin_password = "YourSecureADPassword123!"  # Strong password

# Recommended changes:
allowed_cidr_blocks = ["YOUR_IP/32"]  # Restrict to your IP
```

### 4. Deploy Infrastructure

```bash
# Initialize Terraform
terraform init

# Preview changes
terraform plan

# Apply configuration (takes ~15-20 minutes)
terraform apply

# Type 'yes' when prompted
```

### 5. Access Open WebUI

After deployment completes:

```bash
# Get the Open WebUI URL
terraform output open_webui_url

# Output: http://1.2.3.4:8080
```

Open the URL in your browser and complete the initial setup.

## Deployment Timeline

| Step | Duration | Notes |
|------|----------|-------|
| VPC & Networking | 2-3 min | VPC, subnets, IGW, NAT Gateway |
| AWS Managed AD | 10-15 min | Slowest component to provision |
| RDS PostgreSQL | 5-7 min | Database creation |
| EC2 Instances | 3-5 min | Includes user data execution |
| **Total** | **20-30 min** | First deployment |

## Post-Deployment

### Verify Services

```bash
# SSH into Open WebUI instance
terraform output -raw ssh_connection_open_webui | bash

# Check Open WebUI status
sudo docker ps
sudo docker logs open-webui

# SSH into Bedrock Gateway
terraform output -raw ssh_connection_bedrock_gateway | bash

# Check Gateway status
sudo systemctl status bedrock-gateway
sudo journalctl -u bedrock-gateway -f
```

### Test Bedrock Integration

```bash
# Get the Gateway URL
terraform output bedrock_gateway_url

# Test the health endpoint
curl http://<gateway-private-ip>:8000/health

# List available models
curl http://<gateway-private-ip>:8000/api/tags
```

### Configure Active Directory

Open WebUI is **pre-configured** with LDAP authentication to Active Directory:

```bash
# Get AD details
terraform output active_directory_dns_ips
terraform output active_directory_domain_name
```

**Create Test User:**

```bash
# Create a user for testing
./create_test_user.sh testuser TestUser123!

# Or manually:
./create_user_via_ldap.sh testuser TestUser123! <AD_ADMIN_PASSWORD>
```

**Login to Open WebUI:**
- Username: `testuser`
- Password: `TestUser123!`

The LDAP configuration is automatically set up during deployment in `userdata_open_webui.sh`.

## Configuration

### Instance Sizing

Adjust instance types based on your workload:

```hcl
# In terraform.tfvars

# For light demo usage (cost-optimized)
webui_instance_type = "t3.medium"
gateway_instance_type = "t3.medium"
rds_instance_class = "db.t3.small"

# For production workload
webui_instance_type = "t3.xlarge"
gateway_instance_type = "t3.xlarge"
rds_instance_class = "db.m5.large"
```

### Network Security

Restrict access to your IP:

```hcl
# In terraform.tfvars
allowed_cidr_blocks = ["1.2.3.4/32"]  # Your IP address
```

### Bedrock Models

The gateway **automatically discovers** available Claude models from AWS Bedrock API:

- **Claude Sonnet 4.5** - Latest and most capable (uses inference profile)
- **Claude Haiku 4.5** - Fast and efficient (uses inference profile)
- **Claude 3.7 Sonnet** - Enhanced capabilities (uses inference profile)
- **Claude 3 Sonnet** - Balanced performance
- **Claude 3 Haiku** - Fast responses

**Dynamic Discovery**: The gateway queries AWS Bedrock API every hour to refresh the model list. New models are automatically available without code changes.

**Inference Profiles**: Claude 4.5+ models require inference profiles (`global.` prefix). The gateway handles this automatically.

## Troubleshooting

### Open WebUI Not Responding

```bash
# SSH into the instance
ssh -i ~/.ssh/ai-portal-key.pem ec2-user@<open-webui-ip>

# Check Docker status
sudo docker ps
sudo docker logs open-webui

# Restart if needed
cd /opt/open-webui
sudo docker-compose restart
```

### Bedrock Gateway Errors

```bash
# SSH into the gateway instance
ssh -i ~/.ssh/ai-portal-key.pem ec2-user@<gateway-ip>

# Check service status
sudo systemctl status bedrock-gateway

# View logs
sudo journalctl -u bedrock-gateway -n 100 --no-pager

# Restart service
sudo systemctl restart bedrock-gateway
```

### Database Connection Issues

```bash
# Verify RDS endpoint
terraform output rds_endpoint

# Test connection from Open WebUI instance
psql -h <rds-endpoint> -U aiportaladmin -d aiportal

# Check security group rules
aws ec2 describe-security-groups \
  --group-ids <rds-security-group-id> \
  --region eu-west-2
```

### Bedrock Access Denied

```bash
# Verify IAM role is attached to instances
aws ec2 describe-instances \
  --instance-ids <instance-id> \
  --query 'Reservations[0].Instances[0].IamInstanceProfile'

# Check Bedrock model access
aws bedrock list-foundation-models --region eu-west-2

# Test Bedrock access from instance
aws bedrock-runtime invoke-model \
  --model-id anthropic.claude-3-haiku-20240307-v1:0 \
  --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":100,"messages":[{"role":"user","content":"Hello"}]}' \
  --region eu-west-2 \
  output.txt
```

## Cleanup

To destroy all resources and stop incurring costs:

```bash
# Destroy infrastructure
terraform destroy

# Type 'yes' when prompted
```

**Warning:** This will permanently delete:
- All EC2 instances and their data
- RDS database (unless final snapshot is taken)
- Active Directory domain
- All networking components

## Security Considerations

1. **Passwords**: Use strong, unique passwords for database and AD
2. **Network Access**: Restrict `allowed_cidr_blocks` to your IP
3. **SSH Keys**: Keep EC2 private keys secure
4. **Secrets**: Consider using AWS Secrets Manager for sensitive data
5. **Encryption**: All EBS volumes and RDS storage are encrypted
6. **HTTPS**: Consider adding an ALB with SSL certificate for production
7. **Backups**: RDS automated backups are enabled (7-day retention)

## Cost Optimization

### For Development/Testing

```hcl
# Minimize costs for testing
webui_instance_type = "t3.small"
gateway_instance_type = "t3.small"
rds_instance_class = "db.t3.micro"
```

### Stop Infrastructure When Not In Use

```bash
# Stop EC2 instances (keeps data, stops compute charges)
aws ec2 stop-instances --instance-ids <instance-id> --region eu-west-2

# Start instances when needed
aws ec2 start-instances --instance-ids <instance-id> --region eu-west-2
```

**Note:** AWS Managed AD and NAT Gateway continue charging when stopped. Use `terraform destroy` for complete cost elimination.

## Architecture Details

### Network Design

- **VPC**: 10.0.0.0/16
- **Public Subnets**: 10.0.0.0/24, 10.0.1.0/24 (EC2 instances)
- **Private Subnets**: 10.0.10.0/24, 10.0.11.0/24 (RDS, AD)
- **Multi-AZ**: Resources distributed across 2 availability zones

### Security Groups

- **Open WebUI SG**: Allows HTTP/HTTPS/8080 from allowed_cidr_blocks
- **Bedrock Gateway SG**: Allows internal VPC traffic + SSH
- **RDS SG**: Allows PostgreSQL (5432) from EC2 instances only
- **AD SG**: Allows LDAP/Kerberos/DNS from VPC

### IAM Permissions

EC2 instances have permissions to:
- Invoke Bedrock models
- Stream responses from Bedrock

## Support

For issues or questions:

1. Check the [Troubleshooting](#troubleshooting) section
2. Review CloudWatch logs in AWS Console
3. Verify Bedrock model access in AWS Bedrock console

## License

This infrastructure code is provided as-is for demonstration purposes.
