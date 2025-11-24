#!/bin/bash
set -e

# Update system
yum update -y

# Install Docker
yum install -y docker
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

# Install PostgreSQL client for troubleshooting
yum install -y postgresql15

# Create application directory
mkdir -p /opt/open-webui
cd /opt/open-webui

# Wait for Keycloak to be ready before configuring OIDC
echo "Waiting for Keycloak to be ready..."
KEYCLOAK_URL="${keycloak_url}"
MAX_WAIT=600  # 10 minutes (Keycloak takes time to boot)
ELAPSED=0

while ! curl -sf "$KEYCLOAK_URL/realms/master" > /dev/null 2>&1; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "WARNING: Keycloak not ready after $MAX_WAIT seconds, configuring anyway..."
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    echo "Waiting for Keycloak... ($ELAPSED/$MAX_WAIT seconds)"
done

# Create environment file with OIDC configuration
cat > .env <<EOF
WEBUI_SECRET_KEY=$(openssl rand -hex 32)
OLLAMA_BASE_URL=http://${bedrock_gateway}:8000
ENABLE_SIGNUP=false
ENABLE_LOGIN_FORM=false
DEFAULT_USER_ROLE=user
ENABLE_PERSISTENT_CONFIG=false
ENABLE_OAUTH_SIGNUP=true
OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true
OPENID_PROVIDER_URL=${keycloak_url}/realms/aiportal/.well-known/openid-configuration
OAUTH_CLIENT_ID=openwebui
OAUTH_CLIENT_SECRET=openwebui-secret-change-this
OAUTH_SCOPES=openid email profile
ENABLE_COMMUNITY_SHARING=false
ENABLE_MESSAGE_RATING=false
SAVE_CHAT_HISTORY=false
EOF

# Create docker-compose.yml
cat > docker-compose.yml <<'EOF'
version: '3.8'

services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: always
    ports:
      - "8080:8080"
    volumes:
      - open-webui-data:/app/backend/data
    env_file:
      - .env

volumes:
  open-webui-data:
EOF

# Start the application
docker-compose up -d

# Create a systemd service to ensure it starts on boot
cat > /etc/systemd/system/open-webui.service <<EOF
[Unit]
Description=Open WebUI Docker Compose
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/open-webui
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable open-webui.service

# Setup log rotation
cat > /etc/logrotate.d/open-webui <<EOF
/var/lib/docker/containers/*/*.log {
  rotate 7
  daily
  compress
  size=50M
  missingok
  delaycompress
  copytruncate
}
EOF

echo "Open WebUI installation completed successfully!"

# Wait for Bedrock Gateway to be ready and sync models
echo "Waiting for Bedrock Gateway to be ready..."
GATEWAY_IP="${bedrock_gateway}"
MAX_WAIT=300  # 5 minutes
ELAPSED=0

while ! curl -sf http://$GATEWAY_IP:8000/health > /dev/null 2>&1; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "ERROR: Bedrock Gateway did not become ready after $MAX_WAIT seconds"
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo "Waiting for Bedrock Gateway... ($ELAPSED/$MAX_WAIT seconds)"
done

if curl -sf http://$GATEWAY_IP:8000/health > /dev/null 2>&1; then
    echo "Bedrock Gateway is ready! Syncing models to Open WebUI..."

    # Wait a bit for Open WebUI container to fully initialize
    sleep 10

    # Sync models from Bedrock Gateway
    echo "Starting model sync process..."
    if docker exec -i open-webui python3 <<'PYTHON_EOF'
import os
import requests
import json
from datetime import datetime
import time

os.environ['DATA_DIR'] = '/app/backend/data'

# Wait for database to be ready
max_retries = 30
for i in range(max_retries):
    try:
        from open_webui.internal.db import engine
        from sqlalchemy import text
        print(f'Database ready after {i} retries')
        break
    except Exception as e:
        if i < max_retries - 1:
            print(f'Waiting for database... ({i+1}/{max_retries})')
            time.sleep(2)
        else:
            print(f'ERROR: Database not ready after {max_retries} retries: {e}')
            import sys
            sys.exit(1)

# Get models from Bedrock Gateway
print('Fetching models from Bedrock Gateway...')
response = requests.get('http://${bedrock_gateway}:8000/api/tags', timeout=10)
response.raise_for_status()
models_data = response.json()['models']
print(f'Found {len(models_data)} models')

with engine.connect() as conn:
    # Clear existing models
    conn.execute(text('DELETE FROM model'))

    # Insert models with NULL access_control (= available to all users)
    for model in models_data:
        model_id = model['model']
        created_at = int(datetime.now().timestamp())

        conn.execute(
            text('''
                INSERT INTO model (id, user_id, base_model_id, name, params, meta, created_at, updated_at, is_active, access_control)
                VALUES (:id, '', :base_model_id, :name, '{}', :meta, :created_at, :updated_at, 1, NULL)
            '''),
            {
                'id': model_id,
                'base_model_id': model_id,
                'name': model['name'],
                'meta': json.dumps({'description': model.get('digest', '')}),
                'created_at': created_at,
                'updated_at': created_at
            }
        )

    conn.commit()

    # Verify
    result = conn.execute(text('SELECT COUNT(*) FROM model WHERE is_active = 1'))
    count = result.fetchone()[0]
    print(f'Successfully synced {count} models to Open WebUI!')

# Exit with success
import sys
sys.exit(0)
PYTHON_EOF
    then
        echo "✅ Model sync complete! Open WebUI is ready to use."
    else
        echo "❌ Model sync failed - check logs above for details"
        echo "You can run ./sync_models.sh manually after deployment"
    fi
else
    echo "⚠️  Bedrock Gateway not reachable - models not synced"
    echo "Run ./sync_models.sh manually after deployment"
fi

# ========================================
# Enable DS Data Access & Create Test User
# ========================================
# These are still needed for Keycloak LDAP federation
echo "Enabling Directory Data Access..."
aws ds enable-directory-data-access \
  --directory-id "${ad_directory_id}" \
  --region ${aws_region} 2>/dev/null || echo "DS Data Access already enabled"

echo "Waiting 30 seconds for DS Data Access to be ready..."
sleep 30

# Create Admin user in Active Directory first
echo "Creating Admin user in Active Directory..."
aws ds-data create-user \
  --directory-id "${ad_directory_id}" \
  --sam-account-name Admin \
  --given-name "Admin" \
  --surname "User" \
  --email-address "admin@corp.aiportal.local" \
  --region ${aws_region} || echo "⚠️  Admin user may already exist"

# Explicitly set email address (create-user may not set it properly)
echo "Setting Admin email address..."
aws ds-data update-user \
  --directory-id "${ad_directory_id}" \
  --sam-account-name Admin \
  --email-address "admin@corp.aiportal.local" \
  --region ${aws_region} || echo "⚠️  Failed to set Admin email"

# NOTE: Admin password is set to ad_admin_password (used as LDAP bind credential)
# Do NOT reset it here as it would break Keycloak LDAP authentication
echo "Setting Admin password to match LDAP bind credential..."
aws ds reset-user-password \
  --directory-id "${ad_directory_id}" \
  --user-name Admin \
  --new-password "${ad_admin_password}" \
  --region ${aws_region} || echo "⚠️  Failed to set Admin password"

# Wait for LDAP sync in Keycloak
echo "Waiting 15 seconds for LDAP sync to Keycloak..."
sleep 15

# Create Admin user in Open WebUI database with admin role
echo "Creating Admin account in Open WebUI database..."
docker exec -i open-webui python3 <<'ADMIN_SETUP'
import os
import time
os.environ['DATA_DIR'] = '/app/backend/data'

# Wait for database
max_retries = 10
for i in range(max_retries):
    try:
        from open_webui.internal.db import engine
        from sqlalchemy import text
        break
    except Exception as e:
        if i < max_retries - 1:
            time.sleep(2)
        else:
            print(f'ERROR: Database not ready: {e}')
            import sys
            sys.exit(1)

# Create Admin user with admin role
with engine.connect() as conn:
    # Check if Admin already exists
    result = conn.execute(text("SELECT id FROM user WHERE email = 'admin@corp.aiportal.local'"))
    if result.fetchone() is None:
        # Create Admin user
        import uuid
        from datetime import datetime
        user_id = str(uuid.uuid4())
        timestamp = int(datetime.now().timestamp())

        conn.execute(
            text("""
                INSERT INTO user (id, name, email, role, profile_image_url, created_at, updated_at, last_active_at, api_key, settings, info)
                VALUES (:id, :name, :email, 'admin', '/user.png', :created_at, :updated_at, :last_active_at, NULL, '{}', '{}')
            """),
            {
                'id': user_id,
                'name': 'Admin',
                'email': 'admin@corp.aiportal.local',
                'created_at': timestamp,
                'updated_at': timestamp,
                'last_active_at': timestamp
            }
        )
        conn.commit()
        print('✅ Admin user created with admin role')
    else:
        # Update existing user to admin role
        conn.execute(text("UPDATE user SET role = 'admin' WHERE email = 'admin@corp.aiportal.local'"))
        conn.commit()
        print('✅ Admin user promoted to admin role')
ADMIN_SETUP

# Now create testuser as regular user
echo "Creating testuser in Active Directory..."
aws ds-data create-user \
  --directory-id "${ad_directory_id}" \
  --sam-account-name testuser \
  --given-name "Test" \
  --surname "User" \
  --email-address "testuser@corp.aiportal.local" \
  --region ${aws_region} || echo "⚠️  testuser may already exist"

echo "Setting testuser password..."
aws ds reset-user-password \
  --directory-id "${ad_directory_id}" \
  --user-name testuser \
  --new-password "Welcome@2024" \
  --region ${aws_region} || echo "⚠️  Failed to set password"

echo "✅ Open WebUI setup complete!"
echo "✅ Login via Keycloak at: ${open_webui_url}"
echo ""
echo "Admin user (admin role):"
echo "  Username: Admin"
echo "  Password: ${ad_admin_password}"
echo ""
echo "Test user (regular user):"
echo "  Username: testuser"
echo "  Password: Welcome@2024"
