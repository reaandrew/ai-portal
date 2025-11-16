#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${RED}========================================${NC}"
echo -e "${RED}AI Portal - Infrastructure Destruction${NC}"
echo -e "${RED}========================================${NC}"
echo ""

echo -e "${YELLOW}WARNING: This will permanently delete:${NC}"
echo "  - All EC2 instances and their data"
echo "  - RDS PostgreSQL database"
echo "  - AWS Managed Microsoft AD"
echo "  - All networking components (VPC, subnets, etc.)"
echo "  - All security groups and IAM roles"
echo ""

# Show current resources
echo -e "${YELLOW}Current infrastructure:${NC}"
terraform show -no-color | head -20
echo "..."
echo ""

echo -e "${RED}This action CANNOT be undone!${NC}"
echo ""
read -p "Type 'destroy' to confirm destruction: " -r
echo

if [[ ! $REPLY == "destroy" ]]; then
    echo -e "${GREEN}Destruction cancelled${NC}"
    exit 0
fi

echo ""
read -p "Are you absolutely sure? (yes/no) " -r
echo

if [[ ! $REPLY == "yes" ]]; then
    echo -e "${GREEN}Destruction cancelled${NC}"
    exit 0
fi

echo -e "${YELLOW}Destroying infrastructure...${NC}"
terraform destroy -auto-approve

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Infrastructure Destroyed${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo "All AWS resources have been removed."
echo "You are no longer incurring charges for this infrastructure."
echo ""

# Check if key pair should be removed
echo -e "${YELLOW}Do you want to delete the EC2 key pair and SSH key file?${NC}"
read -p "Delete ai-portal-key? (y/n) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    aws ec2 delete-key-pair --key-name ai-portal-key --region eu-west-2 2>/dev/null || true
    rm -f ~/.ssh/ai-portal-key.pem
    echo -e "${GREEN}✓ Key pair deleted${NC}"
fi

echo ""
echo -e "${GREEN}Cleanup complete!${NC}"
