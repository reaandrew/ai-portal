#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="eu-west-2"
KEY_NAME="ai-portal-key"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}AI Portal - AWS Infrastructure Deployment${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed${NC}"
    echo "Install it from: https://aws.amazon.com/cli/"
    exit 1
fi

# Check if Terraform is installed
if ! command -v terraform &> /dev/null; then
    echo -e "${RED}Error: Terraform is not installed${NC}"
    echo "Install it from: https://www.terraform.io/downloads"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}Error: AWS credentials not configured${NC}"
    echo "Run: aws configure"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites check passed${NC}"
echo ""

# Check if EC2 key pair exists
echo -e "${YELLOW}Checking for EC2 key pair...${NC}"
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$AWS_REGION" &> /dev/null; then
    echo -e "${YELLOW}Key pair '$KEY_NAME' not found. Creating...${NC}"

    # Create key pair
    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --region "$AWS_REGION" \
        --query 'KeyMaterial' \
        --output text > ~/.ssh/${KEY_NAME}.pem

    # Set proper permissions
    chmod 400 ~/.ssh/${KEY_NAME}.pem

    echo -e "${GREEN}✓ Created key pair: ~/.ssh/${KEY_NAME}.pem${NC}"
else
    echo -e "${GREEN}✓ Key pair '$KEY_NAME' already exists${NC}"
fi
echo ""

# Check if terraform.tfvars exists
if [ ! -f terraform.tfvars ]; then
    echo -e "${YELLOW}Creating terraform.tfvars from example...${NC}"
    cp terraform.tfvars.example terraform.tfvars

    # Update key_name in terraform.tfvars
    sed -i.bak "s/your-ec2-keypair-name/$KEY_NAME/" terraform.tfvars
    rm terraform.tfvars.bak 2>/dev/null || true

    echo -e "${RED}IMPORTANT: Please edit terraform.tfvars and update:${NC}"
    echo "  - db_password (use a strong password)"
    echo "  - ad_admin_password (use a strong password)"
    echo "  - allowed_cidr_blocks (restrict to your IP for security)"
    echo ""
    read -p "Press Enter after updating terraform.tfvars to continue..."
fi

# Get current public IP
echo -e "${YELLOW}Detecting your public IP address...${NC}"
PUBLIC_IP=$(curl -s https://api.ipify.org)
if [ -n "$PUBLIC_IP" ]; then
    echo -e "${GREEN}Your public IP: $PUBLIC_IP${NC}"
    echo -e "${YELLOW}Recommendation: Update allowed_cidr_blocks in terraform.tfvars to:${NC}"
    echo "  allowed_cidr_blocks = [\"$PUBLIC_IP/32\"]"
    echo ""
fi

# Verify Bedrock model access
echo -e "${YELLOW}Checking Bedrock model access...${NC}"
echo "Please ensure you have enabled Claude models in AWS Bedrock console:"
echo "  AWS Console > Bedrock > Model access > Manage model access"
echo ""
read -p "Have you enabled Bedrock model access? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Please enable Bedrock model access before continuing${NC}"
    exit 1
fi

# Initialize Terraform
echo -e "${YELLOW}Initializing Terraform...${NC}"
terraform init

# Validate configuration
echo -e "${YELLOW}Validating Terraform configuration...${NC}"
terraform validate

# Show plan
echo -e "${YELLOW}Generating deployment plan...${NC}"
terraform plan -out=tfplan

# Confirm deployment
echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Ready to Deploy${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo "Estimated deployment time: 20-30 minutes"
echo "Estimated cost (1 hour): ~£1.60-£1.70"
echo ""
echo "This will create:"
echo "  - VPC with public/private subnets"
echo "  - 2x EC2 instances (t3.large)"
echo "  - RDS PostgreSQL (db.t3.medium)"
echo "  - AWS Managed Microsoft AD"
echo "  - NAT Gateway, Internet Gateway"
echo "  - Security Groups, IAM Roles"
echo ""
read -p "Do you want to proceed with deployment? (yes/no) " -r
echo

if [[ ! $REPLY == "yes" ]]; then
    echo -e "${RED}Deployment cancelled${NC}"
    exit 1
fi

# Apply Terraform
echo -e "${GREEN}Deploying infrastructure...${NC}"
terraform apply tfplan

# Show outputs
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Display important outputs
echo -e "${YELLOW}Access Information:${NC}"
terraform output open_webui_url
echo ""
terraform output ssh_connection_open_webui
terraform output ssh_connection_bedrock_gateway
echo ""

echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Wait 2-3 minutes for user data scripts to complete"
echo "2. Access Open WebUI at the URL shown above"
echo "3. Complete initial setup in the web interface"
echo "4. Configure LDAP/AD authentication if needed"
echo ""

echo -e "${YELLOW}Verify Installation:${NC}"
echo "SSH into Open WebUI and check:"
echo "  sudo docker ps"
echo "  sudo docker logs open-webui"
echo ""

echo -e "${GREEN}Deployment successful!${NC}"
