#!/bin/bash
# Set AD user as admin in Open WebUI
# Usage: ./set_ad_admin.sh <email>

EMAIL=${1}

if [ -z "$EMAIL" ]; then
    echo "Usage: $0 <email>"
    echo "Example: $0 user@corp.aiportal.local"
    exit 1
fi

# Get values from Terraform outputs
WEBUI_IP=$(terraform output -raw open_webui_public_ip 2>/dev/null)
DB_ENDPOINT=$(terraform output -raw rds_endpoint 2>/dev/null)
DB_NAME=$(terraform output -raw rds_database_name 2>/dev/null)

if [ -z "$WEBUI_IP" ] || [ -z "$DB_ENDPOINT" ] || [ -z "$DB_NAME" ]; then
    echo "Error: Unable to retrieve Terraform outputs"
    echo "Make sure Terraform has been applied successfully"
    exit 1
fi

# Get database credentials from terraform.tfvars
DB_USER=$(grep '^db_username' terraform.tfvars | cut -d'=' -f2 | tr -d ' "')
DB_PASSWORD=$(grep '^db_password' terraform.tfvars | cut -d'=' -f2 | tr -d ' "')

if [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
    echo "Error: Unable to read database credentials from terraform.tfvars"
    exit 1
fi

# Remove :5432 from endpoint if present
DB_HOST=$(echo $DB_ENDPOINT | cut -d':' -f1)

echo "Setting $EMAIL as admin in Open WebUI..."

ssh -o StrictHostKeyChecking=no ec2-user@$WEBUI_IP "sudo docker exec -i open-webui python3 <<EOF
import os
os.environ[\"DATABASE_URL\"] = \"postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:5432/${DB_NAME}\"

from sqlalchemy import create_engine, text
engine = create_engine(os.environ["DATABASE_URL"])

with engine.connect() as conn:
    result = conn.execute(text("UPDATE \"user\" SET role = '"'"'admin'"'"' WHERE email = '"'"'${EMAIL}'"'"'"))
    conn.commit()

    if result.rowcount > 0:
        print(f"✅ Successfully set ${EMAIL} as admin")

        # Show updated user
        result = conn.execute(text("SELECT name, email, role FROM \"user\" WHERE email = '"'"'${EMAIL}'"'"'"))
        for row in result:
            print(f"   Name: {row[0]}, Email: {row[1]}, Role: {row[2]}")
    else:
        print(f"❌ User ${EMAIL} not found")
        print("User must login via LDAP first to create their account")
EOF
'

echo ""
echo "Done! User needs to logout and login again to see admin panel."
