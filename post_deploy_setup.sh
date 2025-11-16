#!/bin/bash
# Post-deployment setup script
# Run this after terraform apply completes
# Usage: ./post_deploy_setup.sh [username] [password] [email]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DEFAULT_USERNAME="admin"
DEFAULT_PASSWORD="Welcome@2024"
DEFAULT_EMAIL="${DEFAULT_USERNAME}@corp.aiportal.local"

USERNAME=${1:-$DEFAULT_USERNAME}
PASSWORD=${2:-$DEFAULT_PASSWORD}
EMAIL=${3:-$DEFAULT_EMAIL}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}AI Portal - Post-Deployment Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo "This script will:"
echo "  1. Wait for infrastructure to be ready"
echo "  2. Verify EC2 instances are running"
echo "  3. Create Active Directory user: $USERNAME"
echo "  4. Set user as admin in Open WebUI"
echo "  5. Verify services are healthy"
echo ""

read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Setup cancelled"
    exit 0
fi

# Check if terraform state exists
if [ ! -f terraform.tfstate ] && [ ! -f .terraform/terraform.tfstate ]; then
    echo -e "${RED}Error: No terraform state found${NC}"
    echo "Run 'terraform apply' first"
    exit 1
fi

echo ""
echo -e "${YELLOW}Step 1: Retrieving infrastructure information...${NC}"

# Get terraform outputs
AD_DIR_ID=$(terraform output -raw active_directory_id 2>/dev/null)
WEBUI_IP=$(terraform output -raw open_webui_public_ip 2>/dev/null)
GATEWAY_IP=$(terraform output -raw bedrock_gateway_public_ip 2>/dev/null)
GATEWAY_PRIVATE_IP=$(terraform output -raw bedrock_gateway_private_ip 2>/dev/null)
AI_PORTAL_URL=$(terraform output -raw ai_portal_url 2>/dev/null)

if [ -z "$AD_DIR_ID" ] || [ -z "$WEBUI_IP" ] || [ -z "$GATEWAY_IP" ]; then
    echo -e "${RED}Error: Unable to retrieve terraform outputs${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Infrastructure information retrieved${NC}"
echo "  Active Directory ID: $AD_DIR_ID"
echo "  Open WebUI IP: $WEBUI_IP"
echo "  Bedrock Gateway IP: $GATEWAY_IP"
echo "  AI Portal URL: $AI_PORTAL_URL"

echo ""
echo -e "${YELLOW}Step 2: Waiting for EC2 instances to be ready...${NC}"
echo "This may take 2-3 minutes for userdata scripts to complete"

# Wait for SSH to be available on Open WebUI
MAX_ATTEMPTS=30
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$WEBUI_IP/22" 2>/dev/null; then
        echo -e "${GREEN}✓ Open WebUI instance is accessible${NC}"
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    echo -n "."
    sleep 10
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    echo -e "${RED}✗ Timeout waiting for Open WebUI instance${NC}"
    exit 1
fi

# Wait for Docker to be running on Open WebUI
echo ""
echo "Waiting for Docker services to start..."
sleep 60  # Give userdata time to run

# Check if Open WebUI container is running
ATTEMPT=0
while [ $ATTEMPT -lt 20 ]; do
    DOCKER_STATUS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@$WEBUI_IP 'sudo docker ps --filter name=open-webui --format "{{.Status}}"' 2>/dev/null || echo "")

    if [[ "$DOCKER_STATUS" == *"Up"* ]]; then
        echo -e "${GREEN}✓ Open WebUI container is running${NC}"
        break
    fi

    ATTEMPT=$((ATTEMPT + 1))
    echo -n "."
    sleep 10
done

if [ $ATTEMPT -eq 20 ]; then
    echo -e "${YELLOW}⚠ Warning: Open WebUI container may not be ready yet${NC}"
    echo "You may need to wait a few more minutes"
fi

echo ""
echo -e "${YELLOW}Step 3: Creating Active Directory user...${NC}"
echo "Username: $USERNAME"
echo "Email: $EMAIL"

# Create AD user
aws-vault exec personal -- aws ds-data create-user \
  --directory-id "$AD_DIR_ID" \
  --sam-account-name "$USERNAME" \
  --given-name "${USERNAME^}" \
  --surname "User" \
  --email-address "$EMAIL" \
  --region eu-west-2 2>/dev/null

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ User created successfully${NC}"
else
    echo -e "${YELLOW}⚠ User may already exist, continuing...${NC}"
fi

# Set password
echo "Setting password..."
aws-vault exec personal -- aws ds reset-user-password \
  --directory-id "$AD_DIR_ID" \
  --user-name "$USERNAME" \
  --new-password "$PASSWORD" \
  --region eu-west-2 2>/dev/null

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Password set successfully${NC}"
else
    echo -e "${RED}✗ Failed to set password${NC}"
    echo "Password must meet complexity requirements"
    exit 1
fi

echo ""
echo -e "${YELLOW}Step 4: Logging in user to create account in Open WebUI...${NC}"
echo "Waiting 30 seconds for AD to sync..."
sleep 30

echo "User needs to login via the web interface first to create their account"
echo "Then we can promote them to admin"
echo ""
echo "Login credentials:"
echo "  URL: $AI_PORTAL_URL"
echo "  Email: $EMAIL"
echo "  Password: $PASSWORD"
echo ""
read -p "Press Enter after you've logged in via the web interface..."

echo ""
echo -e "${YELLOW}Step 5: Promoting user to admin...${NC}"

# Run set_ad_admin.sh
./set_ad_admin.sh "$EMAIL"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ User promoted to admin${NC}"
else
    echo -e "${YELLOW}⚠ Failed to promote user to admin${NC}"
    echo "You may need to login via web first, then run:"
    echo "  ./set_ad_admin.sh $EMAIL"
fi

echo ""
echo -e "${YELLOW}Step 6: Verifying services...${NC}"

# Check Bedrock Gateway
echo -n "Checking Bedrock Gateway... "
GATEWAY_HEALTH=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@$WEBUI_IP "curl -s http://${GATEWAY_PRIVATE_IP}:8000/health" 2>/dev/null || echo "")

if [[ "$GATEWAY_HEALTH" == *"healthy"* ]]; then
    echo -e "${GREEN}✓ Healthy${NC}"
else
    echo -e "${YELLOW}⚠ Not responding (may need more time)${NC}"
fi

# Check models available
echo -n "Checking Bedrock models... "
MODELS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@$WEBUI_IP "curl -s http://${GATEWAY_PRIVATE_IP}:8000/api/tags | jq -r '.models | length'" 2>/dev/null || echo "0")

if [ "$MODELS" -gt 0 ]; then
    echo -e "${GREEN}✓ $MODELS models available${NC}"
else
    echo -e "${YELLOW}⚠ No models detected${NC}"
    echo "  Make sure Bedrock model access is enabled in AWS Console"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Post-Deployment Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}Access Information:${NC}"
echo "  Portal URL: $AI_PORTAL_URL"
echo "  Username: $EMAIL"
echo "  Password: $PASSWORD"
echo ""

echo -e "${BLUE}Admin User:${NC}"
echo "  Email: $EMAIL"
echo "  Role: Admin"
echo ""

echo -e "${YELLOW}Next Steps:${NC}"
echo "  1. Access the portal at: $AI_PORTAL_URL"
echo "  2. Login with the credentials above"
echo "  3. Start chatting with Bedrock models!"
echo ""

echo -e "${YELLOW}Create Additional Users:${NC}"
echo "  ./create_ad_user.sh <username> <password> <email>"
echo ""

echo -e "${YELLOW}Promote Additional Users to Admin:${NC}"
echo "  ./set_ad_admin.sh <email>"
echo ""

echo -e "${GREEN}Setup successful!${NC}"
