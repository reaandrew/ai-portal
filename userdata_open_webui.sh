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
