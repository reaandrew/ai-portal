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

# Create environment file
# NOTE: Open WebUI v0.6.36 has bugs:
# 1. DATABASE_URL with PostgreSQL causes crashes - use SQLite
# 2. {username} placeholder in LDAP_SEARCH_FILTER broken - omit it
# 3. ENABLE_PERSISTENT_CONFIG unreliable - use environment variables
cat > .env <<EOF
WEBUI_SECRET_KEY=$(openssl rand -hex 32)
OLLAMA_BASE_URL=http://${bedrock_gateway}:8000
ENABLE_SIGNUP=true
ENABLE_OAUTH=false
DEFAULT_USER_ROLE=user
ENABLE_PERSISTENT_CONFIG=false
ENABLE_LDAP=true
LDAP_SERVER_LABEL=Active Directory
LDAP_SERVER_HOST=$(echo "${ad_dns_ips}" | cut -d',' -f1)
LDAP_SERVER_PORT=389
LDAP_USE_TLS=false
LDAP_APP_DN=Admin@corp.aiportal.local
LDAP_APP_PASSWORD=${ad_admin_password}
LDAP_SEARCH_BASE=OU=Users,OU=corp,DC=corp,DC=aiportal,DC=local
LDAP_SEARCH_FILTER=(&(objectClass=user)(objectCategory=person))
LDAP_ATTRIBUTE_FOR_USERNAME=sAMAccountName
LDAP_ATTRIBUTE_FOR_MAIL=mail
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
    docker exec -i open-webui python3 <<'PYTHON_EOF'
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
        break
    except Exception as e:
        if i < max_retries - 1:
            time.sleep(2)
        else:
            raise

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
PYTHON_EOF

    echo "✅ Model sync complete! Open WebUI is ready to use."
else
    echo "⚠️  Bedrock Gateway not reachable - models not synced"
    echo "Run ./sync_models.sh manually after deployment"
fi
