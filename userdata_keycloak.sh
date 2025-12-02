#!/bin/bash
# KEYCLOAK PROVISIONING - Log: /var/log/provisioning.log
exec > >(tee -a /var/log/provisioning.log) 2>&1
set -e
trap 'echo "[KEYCLOAK] ❌ FAILED at line $LINENO"' ERR

log() { echo "[KEYCLOAK] $(date +%H:%M:%S) $1"; }

log "Starting - Region: ${aws_region}, DB: ${db_endpoint}"

log "1/10 System update"
yum update -y

log "2/10 Install Docker & PostgreSQL"
yum install -y docker postgresql15 jq
systemctl start docker && systemctl enable docker
usermod -aG docker ec2-user

log "3/10 Install Docker Compose"
curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

log "4/10 Create Keycloak database"
export PGPASSWORD="${db_password}"
psql "host=${db_endpoint} port=${db_port} dbname=${db_admin_database} user=${db_username} sslmode=${db_sslmode}" -c "CREATE DATABASE ${db_name};" 2>&1 || log "DB may exist"

log "5/10 Create app directory"
mkdir -p /opt/keycloak && cd /opt/keycloak

log "6/10 Create docker-compose.yml"
cat > docker-compose.yml <<'EOF'
version: '3.8'
services:
  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    container_name: keycloak
    restart: always
    ports: ["8080:8080"]
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
    command: [start-dev]
    volumes: [keycloak-data:/opt/keycloak/data]
volumes:
  keycloak-data:
EOF

log "7/10 Start Keycloak"
docker-compose up -d

cat > /etc/systemd/system/keycloak.service <<EOF
[Unit]
Description=Keycloak
Requires=docker.service
After=docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/keycloak
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable keycloak.service

log "8/10 Wait for Keycloak"
for i in {1..60}; do curl -sf http://localhost:8080/realms/master >/dev/null 2>&1 && break; sleep 5; log "Waiting... $((i*5))s"; done

log "9/10 Configure Keycloak"
KC="http://localhost:8080"
TOKEN=$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d "username=${keycloak_admin_user}" -d "password=${keycloak_admin_password}" \
  -d "grant_type=password" -d "client_id=admin-cli" | jq -r '.access_token')

[ -z "$TOKEN" ] || [ "$TOKEN" = "null" ] && { log "❌ Failed to get token"; exit 1; }

# Create realm
curl -s -X POST "$KC/admin/realms" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"realm":"aiportal","enabled":true,"displayName":"AI Portal","sslRequired":"external"}' || true

# Configure LDAP
AD_IP=$(echo "${ad_server}" | cut -d',' -f1)
curl -s -X POST "$KC/admin/realms/aiportal/components" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"active-directory","providerId":"ldap","providerType":"org.keycloak.storage.UserStorageProvider","config":{"enabled":["true"],"vendor":["ad"],"usernameLDAPAttribute":["sAMAccountName"],"rdnLDAPAttribute":["cn"],"uuidLDAPAttribute":["objectGUID"],"userObjectClasses":["person,organizationalPerson,user"],"connectionUrl":["ldap://'$AD_IP'"],"usersDn":["${ad_base_dn}"],"authType":["simple"],"bindDn":["${ad_bind_dn}"],"bindCredential":["${ad_bind_password}"],"searchScope":["2"],"editMode":["READ_ONLY"]}}' || true

# Create OIDC client
curl -s -X POST "$KC/admin/realms/aiportal/clients" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"clientId":"openwebui","enabled":true,"clientAuthenticatorType":"client-secret","secret":"openwebui-secret-change-this","redirectUris":["${openwebui_url}/*"],"webOrigins":["${openwebui_url}","+"],"protocol":"openid-connect","publicClient":false,"standardFlowEnabled":true,"directAccessGrantsEnabled":true}' || true

# Create realm roles for Open WebUI role management
curl -s -X POST "$KC/admin/realms/aiportal/roles" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"admin","description":"Open WebUI Admin"}' || true
curl -s -X POST "$KC/admin/realms/aiportal/roles" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"user","description":"Open WebUI User"}' || true

# Add mappers
CID=$(curl -s "$KC/admin/realms/aiportal/clients" -H "Authorization: Bearer $TOKEN" | jq -r '.[]|select(.clientId=="openwebui")|.id')
[ -n "$CID" ] && {
  curl -s -X POST "$KC/admin/realms/aiportal/clients/$CID/protocol-mappers/models" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"name":"email","protocol":"openid-connect","protocolMapper":"oidc-usermodel-property-mapper","config":{"user.attribute":"email","claim.name":"email","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' || true
  # Add realm roles mapper for Open WebUI role management
  curl -s -X POST "$KC/admin/realms/aiportal/clients/$CID/protocol-mappers/models" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"name":"realm-roles","protocol":"openid-connect","protocolMapper":"oidc-usermodel-realm-role-mapper","config":{"claim.name":"roles","jsonType.label":"String","multivalued":"true","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' || true
}

log "10/10 Verify"
curl -sf "$KC/realms/aiportal" >/dev/null && log "✅ Realm OK" || log "⚠️ Realm check failed"

log "✅ COMPLETE - https://${keycloak_subdomain}.${domain_name}"
