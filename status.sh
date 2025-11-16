#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}AI Portal - Infrastructure Status${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if terraform state exists
if [ ! -f terraform.tfstate ]; then
    echo -e "${RED}No infrastructure found${NC}"
    echo "Run ./deploy.sh to deploy the infrastructure"
    exit 1
fi

# Get outputs
echo -e "${GREEN}Access URLs:${NC}"
terraform output -raw open_webui_url 2>/dev/null && echo "" || echo "Not available"
echo ""

echo -e "${GREEN}Public IP Addresses:${NC}"
echo -n "Open WebUI: "
terraform output -raw open_webui_public_ip 2>/dev/null && echo "" || echo "Not available"
echo -n "Bedrock Gateway: "
terraform output -raw bedrock_gateway_public_ip 2>/dev/null && echo "" || echo "Not available"
echo ""

echo -e "${GREEN}Database:${NC}"
echo -n "RDS Endpoint: "
terraform output -raw rds_endpoint 2>/dev/null && echo "" || echo "Not available"
echo -n "Database Name: "
terraform output -raw rds_database_name 2>/dev/null && echo "" || echo "Not available"
echo ""

echo -e "${GREEN}Active Directory:${NC}"
echo -n "Domain Name: "
terraform output -raw active_directory_domain_name 2>/dev/null && echo "" || echo "Not available"
echo -n "DNS IPs: "
terraform output -json active_directory_dns_ips 2>/dev/null | jq -r '.[]' | tr '\n' ', ' | sed 's/,$/\n/' || echo "Not available"
echo ""

# Check instance status using AWS CLI
echo -e "${YELLOW}Checking EC2 instance status...${NC}"

OPEN_WEBUI_IP=$(terraform output -raw open_webui_public_ip 2>/dev/null)
GATEWAY_IP=$(terraform output -raw bedrock_gateway_public_ip 2>/dev/null)

if [ -n "$OPEN_WEBUI_IP" ]; then
    # Get instance ID from IP
    WEBUI_INSTANCE_ID=$(aws ec2 describe-instances \
        --filters "Name=ip-address,Values=$OPEN_WEBUI_IP" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null)

    if [ -n "$WEBUI_INSTANCE_ID" ] && [ "$WEBUI_INSTANCE_ID" != "None" ]; then
        WEBUI_STATE=$(aws ec2 describe-instances \
            --instance-ids "$WEBUI_INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text 2>/dev/null)

        echo -n "Open WebUI EC2: "
        if [ "$WEBUI_STATE" == "running" ]; then
            echo -e "${GREEN}$WEBUI_STATE${NC}"
        else
            echo -e "${YELLOW}$WEBUI_STATE${NC}"
        fi
    fi
fi

if [ -n "$GATEWAY_IP" ]; then
    # Get instance ID from IP
    GATEWAY_INSTANCE_ID=$(aws ec2 describe-instances \
        --filters "Name=ip-address,Values=$GATEWAY_IP" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null)

    if [ -n "$GATEWAY_INSTANCE_ID" ] && [ "$GATEWAY_INSTANCE_ID" != "None" ]; then
        GATEWAY_STATE=$(aws ec2 describe-instances \
            --instance-ids "$GATEWAY_INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text 2>/dev/null)

        echo -n "Bedrock Gateway EC2: "
        if [ "$GATEWAY_STATE" == "running" ]; then
            echo -e "${GREEN}$GATEWAY_STATE${NC}"
        else
            echo -e "${YELLOW}$GATEWAY_STATE${NC}"
        fi
    fi
fi

echo ""

# Test connectivity
echo -e "${YELLOW}Testing connectivity...${NC}"

if [ -n "$OPEN_WEBUI_IP" ]; then
    echo -n "Open WebUI (port 8080): "
    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$OPEN_WEBUI_IP/8080" 2>/dev/null; then
        echo -e "${GREEN}✓ Reachable${NC}"
    else
        echo -e "${RED}✗ Not reachable${NC}"
    fi
fi

echo ""

# SSH connection commands
echo -e "${GREEN}SSH Connection Commands:${NC}"
echo "Open WebUI:"
terraform output -raw ssh_connection_open_webui 2>/dev/null && echo "" || echo "Not available"
echo ""
echo "Bedrock Gateway:"
terraform output -raw ssh_connection_bedrock_gateway 2>/dev/null && echo "" || echo "Not available"
echo ""

# Estimated costs
echo -e "${YELLOW}Cost Information:${NC}"
echo "Approximate hourly cost: ~£1.60-£1.70 (infrastructure)"
echo "Note: Bedrock costs are additional and based on token usage"
echo ""

echo -e "${BLUE}========================================${NC}"
