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

# Create AI Portal Usage Dashboard
echo "Creating AI Portal Usage Dashboard..."
mkdir -p /opt/monitoring/grafana-data/dashboards
chmod 777 /opt/monitoring/grafana-data/dashboards

cat > /opt/monitoring/grafana-data/dashboards/openwebui-usage.json << 'DASHBOARD'
{
  "uid": "openwebui-usage",
  "title": "AI Portal - Usage Analytics",
  "tags": ["openwebui", "ai", "usage"],
  "timezone": "browser",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "30s",
  "templating": {
    "list": [
      {
        "name": "group",
        "type": "query",
        "label": "Department",
        "datasource": {"type": "influxdb", "uid": "InfluxDB"},
        "query": "import \"influxdata/influxdb/schema\"\nschema.tagValues(bucket: \"openwebui\", tag: \"user_group\")",
        "refresh": 1,
        "includeAll": true,
        "multi": false,
        "allValue": ".*",
        "current": {"text": "All", "value": "$__all"}
      },
      {
        "name": "model",
        "type": "query",
        "label": "Model",
        "datasource": {"type": "influxdb", "uid": "InfluxDB"},
        "query": "import \"influxdata/influxdb/schema\"\nschema.tagValues(bucket: \"openwebui\", tag: \"model\")",
        "refresh": 1,
        "includeAll": true,
        "multi": false,
        "allValue": ".*",
        "current": {"text": "All", "value": "$__all"}
      }
    ]
  },
  "panels": [
    {
      "id": 1, "title": "", "type": "text",
      "gridPos": {"h": 2, "w": 24, "x": 0, "y": 0},
      "options": {"mode": "markdown", "content": "# AI Portal Usage Dashboard\n**Real-time analytics for Open WebUI usage across departments**"}
    },
    {
      "id": 2, "title": "Total Chats", "type": "stat",
      "gridPos": {"h": 3, "w": 4, "x": 0, "y": 2},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r.model =~ /${model}/)\n  |> filter(fn: (r) => r._field == \"total_tokens\")\n  |> group()\n  |> count()\n  |> map(fn: (r) => ({_value: r._value, _field: \"count\"}))"}],
      "fieldConfig": {"defaults": {"unit": "none", "color": {"mode": "thresholds"}, "thresholds": {"steps": [{"color": "#6C5DD3", "value": null}]}, "displayName": "Chats"}},
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "center", "textMode": "value"}
    },
    {
      "id": 3, "title": "Total Tokens", "type": "stat",
      "gridPos": {"h": 3, "w": 4, "x": 4, "y": 2},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r.model =~ /${model}/)\n  |> filter(fn: (r) => r._field == \"total_tokens\")\n  |> group()\n  |> sum()\n  |> map(fn: (r) => ({_value: r._value, _field: \"tokens\"}))"}],
      "fieldConfig": {"defaults": {"unit": "locale", "color": {"mode": "thresholds"}, "thresholds": {"steps": [{"color": "#22C55E", "value": null}]}, "displayName": "Tokens"}},
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "center", "textMode": "value"}
    },
    {
      "id": 4, "title": "Input Tokens", "type": "stat",
      "gridPos": {"h": 3, "w": 4, "x": 8, "y": 2},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r.model =~ /${model}/)\n  |> filter(fn: (r) => r._field == \"prompt_tokens\")\n  |> group()\n  |> sum()\n  |> map(fn: (r) => ({_value: r._value, _field: \"input\"}))"}],
      "fieldConfig": {"defaults": {"unit": "locale", "color": {"mode": "thresholds"}, "thresholds": {"steps": [{"color": "#3B82F6", "value": null}]}, "displayName": "Input"}},
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "center", "textMode": "value"}
    },
    {
      "id": 5, "title": "Output Tokens", "type": "stat",
      "gridPos": {"h": 3, "w": 4, "x": 12, "y": 2},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r.model =~ /${model}/)\n  |> filter(fn: (r) => r._field == \"completion_tokens\")\n  |> group()\n  |> sum()\n  |> map(fn: (r) => ({_value: r._value, _field: \"output\"}))"}],
      "fieldConfig": {"defaults": {"unit": "locale", "color": {"mode": "thresholds"}, "thresholds": {"steps": [{"color": "#F59E0B", "value": null}]}, "displayName": "Output"}},
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "center", "textMode": "value"}
    },
    {
      "id": 6, "title": "Unique Users", "type": "stat",
      "gridPos": {"h": 3, "w": 4, "x": 16, "y": 2},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r.model =~ /${model}/)\n  |> distinct(column: \"user\")\n  |> count()\n  |> map(fn: (r) => ({_value: r._value, _field: \"users\"}))"}],
      "fieldConfig": {"defaults": {"unit": "none", "color": {"mode": "thresholds"}, "thresholds": {"steps": [{"color": "#EC4899", "value": null}]}, "displayName": "Users"}},
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "center", "textMode": "value"}
    },
    {
      "id": 7, "title": "Models Used", "type": "stat",
      "gridPos": {"h": 3, "w": 4, "x": 20, "y": 2},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> distinct(column: \"model\")\n  |> count()\n  |> map(fn: (r) => ({_value: r._value, _field: \"models\"}))"}],
      "fieldConfig": {"defaults": {"unit": "none", "color": {"mode": "thresholds"}, "thresholds": {"steps": [{"color": "#8B5CF6", "value": null}]}, "displayName": "Models"}},
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "center", "textMode": "value"}
    },
    {
      "id": 10, "title": "Token Usage Over Time", "type": "barchart",
      "gridPos": {"h": 7, "w": 12, "x": 0, "y": 5},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [
        {"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r.model =~ /${model}/)\n  |> filter(fn: (r) => r._field == \"prompt_tokens\")\n  |> aggregateWindow(every: 1h, fn: sum, createEmpty: false)\n  |> map(fn: (r) => ({_time: r._time, _value: r._value, _field: \"Input\"}))"},
        {"refId": "B", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r.model =~ /${model}/)\n  |> filter(fn: (r) => r._field == \"completion_tokens\")\n  |> aggregateWindow(every: 1h, fn: sum, createEmpty: false)\n  |> map(fn: (r) => ({_time: r._time, _value: r._value, _field: \"Output\"}))"}
      ],
      "fieldConfig": {
        "defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 80, "stacking": {"mode": "normal"}}},
        "overrides": [
          {"matcher": {"id": "byName", "options": "Input"}, "properties": [{"id": "color", "value": {"fixedColor": "#3B82F6", "mode": "fixed"}}]},
          {"matcher": {"id": "byName", "options": "Output"}, "properties": [{"id": "color", "value": {"fixedColor": "#22C55E", "mode": "fixed"}}]}
        ]
      },
      "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "barWidth": 0.8, "stacking": "normal"}
    },
    {
      "id": 11, "title": "Chats Per Hour", "type": "barchart",
      "gridPos": {"h": 7, "w": 12, "x": 12, "y": 5},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r.model =~ /${model}/)\n  |> filter(fn: (r) => r._field == \"total_tokens\")\n  |> aggregateWindow(every: 1h, fn: count, createEmpty: false)\n  |> map(fn: (r) => ({_time: r._time, _value: r._value, _field: \"Chats\"}))"}],
      "fieldConfig": {"defaults": {"color": {"fixedColor": "#6C5DD3", "mode": "fixed"}, "custom": {"fillOpacity": 80}}},
      "options": {"legend": {"displayMode": "hidden"}, "barWidth": 0.8}
    },
    {
      "id": 12, "title": "Tokens by Department", "type": "barchart",
      "gridPos": {"h": 7, "w": 8, "x": 0, "y": 12},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r._field == \"total_tokens\")\n  |> group(columns: [\"user_group\"])\n  |> sum()\n  |> map(fn: (r) => ({Department: r.user_group, Tokens: r._value}))"}],
      "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 80}}},
      "options": {"legend": {"displayMode": "hidden"}, "xField": "Department", "barWidth": 0.6}
    },
    {
      "id": 13, "title": "Tokens by Model", "type": "barchart",
      "gridPos": {"h": 7, "w": 8, "x": 8, "y": 12},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r._field == \"total_tokens\")\n  |> group(columns: [\"model\"])\n  |> sum()\n  |> map(fn: (r) => ({Model: r.model, Tokens: r._value}))"}],
      "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 80}}},
      "options": {"legend": {"displayMode": "hidden"}, "xField": "Model", "barWidth": 0.6}
    },
    {
      "id": 14, "title": "Top Users", "type": "table",
      "gridPos": {"h": 7, "w": 8, "x": 16, "y": 12},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r.model =~ /${model}/)\n  |> filter(fn: (r) => r._field == \"total_tokens\")\n  |> group(columns: [\"user\", \"user_group\"])\n  |> sum()\n  |> group()\n  |> sort(columns: [\"_value\"], desc: true)\n  |> limit(n: 10)\n  |> map(fn: (r) => ({User: r.user, Department: r.user_group, Tokens: r._value}))"}],
      "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": [{"matcher": {"id": "byName", "options": "Tokens"}, "properties": [{"id": "unit", "value": "locale"}]}]},
      "options": {"showHeader": true}
    },
    {
      "id": 15, "title": "Chats by Department", "type": "piechart",
      "gridPos": {"h": 7, "w": 8, "x": 0, "y": 19},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r._field == \"total_tokens\")\n  |> group(columns: [\"user_group\"])\n  |> count()\n  |> map(fn: (r) => ({_value: r._value, _field: r.user_group}))"}],
      "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}}},
      "options": {"legend": {"displayMode": "table", "placement": "right", "values": ["value", "percent"]}, "pieType": "pie", "reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "id": 16, "title": "Chats by Model", "type": "piechart",
      "gridPos": {"h": 7, "w": 8, "x": 8, "y": 19},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r._field == \"total_tokens\")\n  |> group(columns: [\"model\"])\n  |> count()\n  |> map(fn: (r) => ({_value: r._value, _field: r.model}))"}],
      "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}}},
      "options": {"legend": {"displayMode": "table", "placement": "right", "values": ["value", "percent"]}, "pieType": "pie", "reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "id": 17, "title": "Avg Tokens/Chat", "type": "stat",
      "gridPos": {"h": 7, "w": 4, "x": 16, "y": 19},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r.model =~ /${model}/)\n  |> filter(fn: (r) => r._field == \"total_tokens\")\n  |> group()\n  |> mean()\n  |> map(fn: (r) => ({_value: r._value, _field: \"avg\"}))"}],
      "fieldConfig": {"defaults": {"unit": "locale", "decimals": 0, "color": {"mode": "thresholds"}, "thresholds": {"steps": [{"color": "#10B981", "value": null}]}, "displayName": "Avg/Chat"}},
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "center", "textMode": "value"}
    },
    {
      "id": 18, "title": "Output/Input Ratio", "type": "gauge",
      "gridPos": {"h": 7, "w": 4, "x": 20, "y": 19},
      "datasource": {"type": "influxdb", "uid": "InfluxDB"},
      "targets": [{"refId": "A", "query": "input = from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r.model =~ /${model}/)\n  |> filter(fn: (r) => r._field == \"prompt_tokens\")\n  |> group()\n  |> sum()\n  |> findRecord(fn: (key) => true, idx: 0)\n\noutput = from(bucket: \"openwebui\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"chat_usage\")\n  |> filter(fn: (r) => r.user_group =~ /${group}/)\n  |> filter(fn: (r) => r.model =~ /${model}/)\n  |> filter(fn: (r) => r._field == \"completion_tokens\")\n  |> group()\n  |> sum()\n  |> findRecord(fn: (key) => true, idx: 0)\n\narray.from(rows: [{_value: float(v: output._value) / float(v: input._value)}])"}],
      "fieldConfig": {"defaults": {"unit": "none", "decimals": 1, "min": 0, "max": 10, "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#3B82F6", "value": null}, {"color": "#22C55E", "value": 2}, {"color": "#F59E0B", "value": 5}]}, "displayName": "Out/In"}},
      "options": {"showThresholdLabels": false, "showThresholdMarkers": true}
    }
  ],
  "time": {"from": "now-7d", "to": "now"}
}
DASHBOARD
echo "Dashboard created: AI Portal - Usage Analytics"

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
echo "Dashboard: ${grafana_url}/d/openwebui-usage"
echo ""
echo "Note: Metrics are collected from OpenWebUI every 5 minutes"
echo "Filter by Department or Model in the dashboard"
