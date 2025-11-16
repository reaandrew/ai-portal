#!/bin/bash
# Create AD user via AWS CLI
# Usage: ./create_ad_user.sh <username> <password> <email>

USERNAME=${1:-testuser}
PASSWORD=${2:-Welcome@2024}
EMAIL=${3:-${USERNAME}@corp.aiportal.local}
AD_DIR_ID=$(terraform output -raw active_directory_id 2>/dev/null)
AD_DOMAIN=$(terraform output -raw active_directory_domain_name 2>/dev/null)

echo "Creating AD user: $USERNAME"
echo "Directory: $AD_DIR_ID"
echo "Domain: $AD_DOMAIN"
echo ""

# Create the user using AWS Directory Service Data API
echo "Creating user..."
aws ds-data create-user \
  --directory-id "$AD_DIR_ID" \
  --sam-account-name "$USERNAME" \
  --given-name "${USERNAME}" \
  --surname "User" \
  --email-address "$EMAIL" \
  --region eu-west-2

if [ $? -eq 0 ]; then
    echo "✅ User created successfully!"
    echo ""

    # Set the password
    echo "Setting password..."
    aws ds reset-user-password \
      --directory-id "$AD_DIR_ID" \
      --user-name "$USERNAME" \
      --new-password "$PASSWORD" \
      --region eu-west-2

    if [ $? -eq 0 ]; then
        echo "✅ Password set successfully!"
        echo ""
        echo "Login credentials for Open WebUI:"
        echo "  Email: ${EMAIL}"
        echo "  Password: $PASSWORD"
        echo ""
        echo "Note: Use the email address format when logging in to Open WebUI"
    else
        echo "❌ Failed to set password"
        echo "Password must meet complexity requirements:"
        echo "  - At least 8 characters"
        echo "  - Uppercase and lowercase letters"
        echo "  - Numbers and special characters"
        echo "  - Cannot contain username or parts of full name"
        echo "  - IMPORTANT: Avoid exclamation marks (!) - Python ldap3 cannot handle them"
    fi
else
    echo "❌ Failed to create user"
    echo "User might already exist. To reset password:"
    echo "  aws ds reset-user-password --directory-id $AD_DIR_ID --user-name $USERNAME --new-password '<password>' --region eu-west-2"
fi
