#!/bin/bash
# Update terraform.tfvars in AWS SSM Parameter Store
# Usage: ./update_ssm_tfvars.sh

set -e

PARAM_NAME="/com/forora/ai-portal/terraform.tfvars"
TFVARS_FILE="terraform.tfvars"

echo "Updating terraform.tfvars in AWS SSM Parameter Store..."
echo "Parameter: $PARAM_NAME"
echo ""

if [ ! -f "$TFVARS_FILE" ]; then
    echo "Error: terraform.tfvars not found in current directory"
    exit 1
fi

# Update the parameter
aws-vault exec personal -- aws ssm put-parameter \
  --name "$PARAM_NAME" \
  --value "file://$PWD/$TFVARS_FILE" \
  --type "SecureString" \
  --description "AI Portal Terraform variables with secrets" \
  --region eu-west-2 \
  --overwrite

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Successfully updated terraform.tfvars in SSM Parameter Store"
    echo ""
    echo "To retrieve later:"
    echo "  aws-vault exec personal -- aws ssm get-parameter \\"
    echo "    --name \"$PARAM_NAME\" \\"
    echo "    --with-decryption \\"
    echo "    --region eu-west-2 \\"
    echo "    --query 'Parameter.Value' \\"
    echo "    --output text > terraform.tfvars"
else
    echo ""
    echo "❌ Failed to update parameter"
    exit 1
fi
