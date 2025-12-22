#!/bin/bash
set -e

# Log all output
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Starting Grafana + InfluxDB Setup ==="

# Update system
dnf update -y
dnf install -y docker git jq

# Start Docker
systemctl enable docker
systemctl start docker

# Install Docker Compose
curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

# Create data directories
mkdir -p /opt/monitoring/influxdb-data
mkdir -p /opt/monitoring/grafana-data
mkdir -p /opt/monitoring/grafana-provisioning/datasources
mkdir -p /opt/monitoring/grafana-provisioning/dashboards
chmod -R 777 /opt/monitoring/grafana-data

# Create InfluxDB datasource provisioning
cat > /opt/monitoring/grafana-provisioning/datasources/influxdb.yaml << 'DATASOURCE'
apiVersion: 1
datasources:
  - name: InfluxDB
    type: influxdb
    access: proxy
    url: http://influxdb:8086
    jsonData:
      version: Flux
      organization: ${influxdb_org}
      defaultBucket: ${influxdb_bucket}
      tlsSkipVerify: true
    secureJsonData:
      token: ${influxdb_token}
    isDefault: true
DATASOURCE

# Create dashboard provisioning config
cat > /opt/monitoring/grafana-provisioning/dashboards/default.yaml << 'DASHPROV'
apiVersion: 1
providers:
  - name: 'default'
    orgId: 1
    folder: 'OpenWebUI'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
DASHPROV

# Create docker-compose.yml
cat > /opt/monitoring/docker-compose.yml << 'COMPOSE'
services:
  influxdb:
    image: influxdb:2.7
    container_name: influxdb
    restart: unless-stopped
    ports:
      - "8086:8086"
    volumes:
      - /opt/monitoring/influxdb-data:/var/lib/influxdb2
    environment:
      - DOCKER_INFLUXDB_INIT_MODE=setup
      - DOCKER_INFLUXDB_INIT_USERNAME=${influxdb_admin_user}
      - DOCKER_INFLUXDB_INIT_PASSWORD=${influxdb_admin_password}
      - DOCKER_INFLUXDB_INIT_ORG=${influxdb_org}
      - DOCKER_INFLUXDB_INIT_BUCKET=${influxdb_bucket}
      - DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=${influxdb_token}
    healthcheck:
      test: ["CMD", "influx", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - /opt/monitoring/grafana-data:/var/lib/grafana
      - /opt/monitoring/grafana-provisioning:/etc/grafana/provisioning
    environment:
      # Basic config
      - GF_SERVER_ROOT_URL=${grafana_url}
      - GF_SERVER_DOMAIN=${grafana_url}

      # Admin credentials (for initial setup / fallback)
      - GF_SECURITY_ADMIN_USER=${grafana_admin_user}
      - GF_SECURITY_ADMIN_PASSWORD=${grafana_admin_password}

      # OAuth/Keycloak configuration
      - GF_AUTH_GENERIC_OAUTH_ENABLED=true
      - GF_AUTH_GENERIC_OAUTH_NAME=Keycloak
      - GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true
      - GF_AUTH_GENERIC_OAUTH_CLIENT_ID=${keycloak_client_id}
      - GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=${keycloak_client_secret}
      - GF_AUTH_GENERIC_OAUTH_SCOPES=openid email profile
      - GF_AUTH_GENERIC_OAUTH_AUTH_URL=${keycloak_url}/realms/${keycloak_realm}/protocol/openid-connect/auth
      - GF_AUTH_GENERIC_OAUTH_TOKEN_URL=${keycloak_url}/realms/${keycloak_realm}/protocol/openid-connect/token
      - GF_AUTH_GENERIC_OAUTH_API_URL=${keycloak_url}/realms/${keycloak_realm}/protocol/openid-connect/userinfo
      - GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(realm_access.roles[*], 'admin') && 'Admin' || contains(realm_access.roles[*], 'editor') && 'Editor' || 'Viewer'
      - GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH=email
      - GF_AUTH_GENERIC_OAUTH_LOGIN_ATTRIBUTE_PATH=preferred_username
      - GF_AUTH_GENERIC_OAUTH_NAME_ATTRIBUTE_PATH=preferred_username
      - GF_AUTH_GENERIC_OAUTH_GROUPS_ATTRIBUTE_PATH=groups
      - GF_AUTH_GENERIC_OAUTH_USE_PKCE=true
      - GF_AUTH_GENERIC_OAUTH_USE_REFRESH_TOKEN=true

      # Allow embedding and anonymous for dashboards if needed
      - GF_AUTH_ANONYMOUS_ENABLED=false
      - GF_SECURITY_ALLOW_EMBEDDING=true

      # Disable basic auth to force OAuth
      - GF_AUTH_DISABLE_LOGIN_FORM=false
      - GF_AUTH_OAUTH_AUTO_LOGIN=false

      # Logging
      - GF_LOG_MODE=console
      - GF_LOG_LEVEL=info
    depends_on:
      influxdb:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
COMPOSE

# Start services
cd /opt/monitoring
docker-compose up -d

# Wait for services to be healthy
echo "Waiting for InfluxDB to be ready..."
sleep 30

# Download and import the OpenWebUI dashboard with group filtering
echo "Downloading OpenWebUI dashboard..."
mkdir -p /opt/monitoring/grafana-data/dashboards
chmod 777 /opt/monitoring/grafana-data/dashboards

# Download official dashboard and add group filtering
curl -s "https://grafana.com/api/dashboards/${grafana_dashboard_id}/revisions/1/download" -o /tmp/dashboard.json

if [ -s /tmp/dashboard.json ]; then
  python3 << 'PYSCRIPT'
import json

with open('/tmp/dashboard.json', 'r') as f:
    dashboard = json.load(f)

# Add AD group variable for filtering
group_var = {
    "name": "user_group",
    "type": "query",
    "label": "AD Group",
    "datasource": {"type": "influxdb", "uid": "InfluxDB"},
    "query": 'import "influxdata/influxdb/schema"\nschema.tagValues(bucket: "openwebui", tag: "user_group")',
    "refresh": 1,
    "includeAll": True,
    "multi": True,
    "allValue": ".*",
    "current": {"text": "All", "value": "$__all"}
}

if 'templating' not in dashboard:
    dashboard['templating'] = {'list': []}
dashboard['templating']['list'].insert(0, group_var)

dashboard['uid'] = 'openwebui-by-group'
dashboard['title'] = 'OpenWebUI Usage by AD Group'

with open('/opt/monitoring/grafana-data/dashboards/openwebui-groups.json', 'w') as f:
    json.dump(dashboard, f, indent=2)
PYSCRIPT
  echo "Dashboard modified with AD group filter"
else
  echo "Dashboard download failed - manual import required"
fi

# Fix permissions
chown -R 472:472 /opt/monitoring/grafana-data

# Restart Grafana to pick up dashboard
docker-compose restart grafana

# Wait for Grafana to be ready
echo "Waiting for Grafana to be ready..."
for i in {1..30}; do
  curl -sf http://localhost:3000/api/health >/dev/null 2>&1 && break
  sleep 2
done

# Delete local admin user (OAuth admin from Keycloak will be used instead)
echo "Removing local admin user (Keycloak OAuth admin will be used)..."
GRAFANA_AUTH="${grafana_admin_user}:${grafana_admin_password}"
curl -s -X DELETE "http://localhost:3000/api/admin/users/1" -u "$GRAFANA_AUTH" || true

# Create teams for AD groups
echo "Creating Grafana teams..."
curl -s -X POST "http://localhost:3000/api/teams" \
  -u "$GRAFANA_AUTH" -H "Content-Type: application/json" \
  -d '{"name":"HMRC","email":"hmrc@aiportal.local"}' || true
curl -s -X POST "http://localhost:3000/api/teams" \
  -u "$GRAFANA_AUTH" -H "Content-Type: application/json" \
  -d '{"name":"DEFRA","email":"defra@aiportal.local"}' || true

echo "=== Grafana + InfluxDB Setup Complete ==="
echo "Grafana URL: ${grafana_url}"
echo "InfluxDB URL: http://localhost:8086"
echo "Dashboard: ${grafana_url}/d/openwebui-by-group"
echo ""
echo "Note: Metrics are collected from OpenWebUI every 5 minutes"
echo "Users can filter by AD group (HMRC/DEFRA) in the dashboard"
