#!/bin/bash
set -e

# Update system
yum update -y

# Install Docker
yum install -y docker postgresql15
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

# Install jq for JSON parsing
yum install -y jq

# Create Keycloak database in PostgreSQL RDS
echo "Creating Keycloak database in RDS..."
export PGPASSWORD="${db_password}"
# Connect to admin database to create keycloak database
psql "host=${db_endpoint} port=${db_port} dbname=${db_admin_database} user=${db_username} sslmode=${db_sslmode}" \
  -c "CREATE DATABASE ${db_name};" || echo "Database may already exist"

# Create application directory
mkdir -p /opt/keycloak
cd /opt/keycloak

# Create docker-compose.yml for Keycloak
cat > docker-compose.yml <<'EOF'
version: '3.8'

services:
  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    container_name: keycloak
    restart: always
    ports:
      - "8080:8080"
    environment:
      KC_DB: postgres
      KC_DB_URL: "jdbc:postgresql://${db_endpoint}:5432/keycloak"
      KC_DB_USERNAME: "${db_username}"
      KC_DB_PASSWORD: "${db_password}"
      KC_HOSTNAME: "${keycloak_subdomain}.${domain_name}"
      KC_HOSTNAME_STRICT: "false"
      KC_PROXY_HEADERS: "xforwarded"
      KC_HTTP_ENABLED: "true"
      KC_HEALTH_ENABLED: "true"
      KEYCLOAK_ADMIN: "${keycloak_admin_user}"
      KEYCLOAK_ADMIN_PASSWORD: "${keycloak_admin_password}"
    command:
      - start-dev
    volumes:
      - keycloak-data:/opt/keycloak/data

volumes:
  keycloak-data:
EOF

# Start Keycloak
echo "Starting Keycloak..."
docker-compose up -d

# Create systemd service
cat > /etc/systemd/system/keycloak.service <<EOF
[Unit]
Description=Keycloak Docker Compose
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/keycloak
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable keycloak.service

echo "Waiting for Keycloak to be ready..."
MAX_WAIT=300
ELAPSED=0
while ! curl -sf http://localhost:8080/realms/master > /dev/null 2>&1; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "ERROR: Keycloak did not become ready after $MAX_WAIT seconds"
        exit 1
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo "Waiting for Keycloak... ($ELAPSED/$MAX_WAIT seconds)"
done

echo "Keycloak is ready! Configuring LDAP and OIDC..."

# Configure Keycloak using Admin REST API
KEYCLOAK_URL="http://localhost:8080"
ADMIN_USER="${keycloak_admin_user}"
ADMIN_PASSWORD="${keycloak_admin_password}"

# Get admin access token
echo "Getting admin access token..."
ADMIN_TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=$ADMIN_USER" \
  -d "password=$ADMIN_PASSWORD" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token')

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
    echo "ERROR: Failed to get admin token"
    exit 1
fi

echo "Admin token obtained successfully"

# Create realm "aiportal"
echo "Creating aiportal realm..."
curl -s -X POST "$KEYCLOAK_URL/admin/realms" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "realm": "aiportal",
    "enabled": true,
    "displayName": "AI Portal",
    "loginTheme": "keycloak",
    "sslRequired": "external"
  }' || echo "Realm may already exist"

# Configure LDAP User Federation
echo "Configuring LDAP user federation..."
AD_SERVER="${ad_server}"
AD_SERVER=$(echo $AD_SERVER | cut -d',' -f1)  # Use first DNS server

cat > /tmp/ldap.json <<LDAP_JSON
{
  "name": "active-directory",
  "providerId": "ldap",
  "providerType": "org.keycloak.storage.UserStorageProvider",
  "config": {
    "enabled": ["true"],
    "priority": ["0"],
    "editMode": ["READ_ONLY"],
    "syncRegistrations": ["false"],
    "vendor": ["ad"],
    "usernameLDAPAttribute": ["sAMAccountName"],
    "rdnLDAPAttribute": ["cn"],
    "uuidLDAPAttribute": ["objectGUID"],
    "userObjectClasses": ["person, organizationalPerson, user"],
    "connectionUrl": ["ldap://$AD_SERVER"],
    "usersDn": ["${ad_base_dn}"],
    "authType": ["simple"],
    "bindDn": ["${ad_bind_dn}"],
    "bindCredential": ["${ad_bind_password}"],
    "searchScope": ["2"],
    "connectionPooling": ["true"],
    "pagination": ["true"]
  }
}
LDAP_JSON

curl -s -X POST "$KEYCLOAK_URL/admin/realms/aiportal/components" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/ldap.json || echo "LDAP component may already exist"

echo "Triggering LDAP user sync..."
sleep 5

# Get LDAP component ID and trigger sync
LDAP_ID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/aiportal/components" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[] | select(.name=="active-directory") | .id')

if [ ! -z "$LDAP_ID" ] && [ "$LDAP_ID" != "null" ]; then
    echo "LDAP Component ID: $LDAP_ID"
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/aiportal/user-storage/$LDAP_ID/sync?action=triggerFullSync" \
      -H "Authorization: Bearer $ADMIN_TOKEN" || echo "Sync may have failed"
fi

# Create OIDC client for Open WebUI
echo "Creating OIDC client for Open WebUI..."
cat > /tmp/client.json <<CLIENT_JSON
{
  "clientId": "openwebui",
  "name": "Open WebUI",
  "description": "OIDC client for Open WebUI",
  "enabled": true,
  "clientAuthenticatorType": "client-secret",
  "secret": "openwebui-secret-change-this",
  "redirectUris": [
    "${openwebui_url}/*",
    "${openwebui_url}/oauth/oidc/callback"
  ],
  "webOrigins": [
    "${openwebui_url}",
    "+"
  ],
  "protocol": "openid-connect",
  "publicClient": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": false,
  "authorizationServicesEnabled": false,
  "fullScopeAllowed": true
}
CLIENT_JSON

curl -s -X POST "$KEYCLOAK_URL/admin/realms/aiportal/clients" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/client.json || echo "Client may already exist"

# Create protocol mappers for user attributes
echo "Creating protocol mappers for OIDC client..."
CLIENT_ID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/aiportal/clients" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[] | select(.clientId=="openwebui") | .id')

if [ ! -z "$CLIENT_ID" ] && [ "$CLIENT_ID" != "null" ]; then
    # Email mapper
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/aiportal/clients/$CLIENT_ID/protocol-mappers/models" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "email",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-usermodel-property-mapper",
        "config": {
          "user.attribute": "email",
          "claim.name": "email",
          "jsonType.label": "String",
          "id.token.claim": "true",
          "access.token.claim": "true",
          "userinfo.token.claim": "true"
        }
      }' || echo "Email mapper may exist"

    # Name mapper
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/aiportal/clients/$CLIENT_ID/protocol-mappers/models" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "name",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-full-name-mapper",
        "config": {
          "id.token.claim": "true",
          "access.token.claim": "true",
          "userinfo.token.claim": "true"
        }
      }' || echo "Name mapper may exist"

    # Username mapper
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/aiportal/clients/$CLIENT_ID/protocol-mappers/models" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "username",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-usermodel-property-mapper",
        "config": {
          "user.attribute": "username",
          "claim.name": "preferred_username",
          "jsonType.label": "String",
          "id.token.claim": "true",
          "access.token.claim": "true",
          "userinfo.token.claim": "true"
        }
      }' || echo "Username mapper may exist"
fi

echo "✅ Keycloak configuration complete!"
echo ""
echo "Keycloak Admin Console: https://${keycloak_subdomain}.${domain_name}"
echo "Admin Username: ${keycloak_admin_user}"
echo "Realm: aiportal"
echo "OIDC Client: openwebui"
echo "Client Secret: openwebui-secret-change-this"
echo ""
echo "OIDC Configuration URL: https://${keycloak_subdomain}.${domain_name}/realms/aiportal/.well-known/openid-configuration"
