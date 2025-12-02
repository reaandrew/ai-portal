#!/bin/bash
# OPEN WEBUI PROVISIONING - Log: /var/log/provisioning.log
exec > >(tee -a /var/log/provisioning.log) 2>&1
set -e
trap 'echo "[OPEN-WEBUI] ❌ FAILED at line $LINENO"' ERR

log() { echo "[OPEN-WEBUI] $(date +%H:%M:%S) $1"; }

log "Starting - Keycloak: ${keycloak_url}, Gateway: ${bedrock_gateway}"

log "1/12 System update"
yum update -y

log "2/12 Install Docker"
yum install -y docker postgresql15 jq
systemctl start docker && systemctl enable docker
usermod -aG docker ec2-user

log "3/12 Install Docker Compose"
curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

log "4/12 Wait for Keycloak (max 10min)"
for i in {1..60}; do curl -sf "${keycloak_url}/realms/master" >/dev/null 2>&1 && break; sleep 10; log "Waiting... $((i*10))s"; done

log "5/12 Create app directory"
mkdir -p /opt/open-webui/pipelines && cd /opt/open-webui

log "6/12 Create pipeline filters"
# Detoxify filter
cat > pipelines/detoxify_filter.py <<'PYEOF'
"""
title: Detoxify Filter
description: Filter toxic messages using Detoxify library
requirements: detoxify
"""
from typing import List, Optional
from pydantic import BaseModel

class Pipeline:
    class Valves(BaseModel):
        pipelines: List[str] = ["*"]
        priority: int = 0
        toxicity_threshold: float = 0.5

    def __init__(self):
        self.type = "filter"
        self.name = "Detoxify Filter"
        self.valves = self.Valves()
        self.model = None

    async def on_startup(self):
        from detoxify import Detoxify
        self.model = Detoxify("original")

    async def on_shutdown(self):
        pass

    async def inlet(self, body: dict, user: Optional[dict] = None) -> dict:
        msg = body["messages"][-1]["content"]
        result = self.model.predict(msg)
        if result["toxicity"] > self.valves.toxicity_threshold:
            raise Exception(f"Message blocked: toxicity score {result['toxicity']:.2f} exceeds threshold")
        return body
PYEOF

# LLM-Guard prompt injection filter
cat > pipelines/llmguard_filter.py <<'PYEOF'
"""
title: LLM-Guard Prompt Injection Filter
description: Detect and block prompt injection attacks
requirements: llm-guard
"""
from typing import List, Optional
from pydantic import BaseModel

class Pipeline:
    class Valves(BaseModel):
        pipelines: List[str] = ["*"]
        priority: int = 1
        risk_threshold: float = 0.8

    def __init__(self):
        self.type = "filter"
        self.name = "LLM-Guard Filter"
        self.valves = self.Valves()
        self.scanner = None

    async def on_startup(self):
        from llm_guard.input_scanners import PromptInjection
        self.scanner = PromptInjection(threshold=self.valves.risk_threshold)

    async def on_shutdown(self):
        pass

    async def inlet(self, body: dict, user: Optional[dict] = None) -> dict:
        msg = body["messages"][-1]["content"]
        sanitized, is_valid, risk = self.scanner.scan(msg)
        if not is_valid:
            raise Exception(f"Prompt injection detected (risk: {risk:.2f})")
        return body
PYEOF

# Conversation turn limit filter
cat > pipelines/turn_limit_filter.py <<'PYEOF'
"""
title: Conversation Turn Limit Filter
description: Limit conversation turns per user role
"""
from typing import List, Optional
from pydantic import BaseModel

class Pipeline:
    class Valves(BaseModel):
        pipelines: List[str] = ["*"]
        priority: int = 2
        max_turns: int = ${max_conversation_turns}
        target_user_roles: List[str] = ["user"]

    def __init__(self):
        self.type = "filter"
        self.name = "Turn Limit Filter"
        self.valves = self.Valves()

    async def on_startup(self):
        pass

    async def on_shutdown(self):
        pass

    async def inlet(self, body: dict, user: Optional[dict] = None) -> dict:
        if user and user.get("role") in self.valves.target_user_roles:
            turns = len([m for m in body.get("messages", []) if m.get("role") == "user"])
            if turns > self.valves.max_turns:
                raise Exception(f"Conversation limit exceeded ({self.valves.max_turns} turns max)")
        return body
PYEOF

log "7/12 Create config files"
cat > .env <<EOF
WEBUI_SECRET_KEY=$(openssl rand -hex 32)
OLLAMA_BASE_URL=http://${bedrock_gateway}:8000
ENABLE_SIGNUP=false
ENABLE_LOGIN_FORM=false
DEFAULT_USER_ROLE=user
ENABLE_OAUTH_SIGNUP=true
OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true
OPENID_PROVIDER_URL=${keycloak_url}/realms/aiportal/.well-known/openid-configuration
OAUTH_CLIENT_ID=openwebui
OAUTH_CLIENT_SECRET=openwebui-secret-change-this
OAUTH_SCOPES=openid email profile
ENABLE_OAUTH_ROLE_MANAGEMENT=true
OAUTH_ROLES_CLAIM=roles
OAUTH_ALLOWED_ROLES=user,admin
OAUTH_ADMIN_ROLES=admin
EOF

cat > docker-compose.yml <<'DCOMPOSE'
version: '3.8'
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: always
    ports: ["8080:8080"]
    volumes: [open-webui-data:/app/backend/data]
    env_file: [.env]
    depends_on: [pipelines]
    environment:
      - OPENAI_API_BASE_URL=http://pipelines:9099
      - OPENAI_API_KEY=0p3n-w3bu!

  pipelines:
    image: ghcr.io/open-webui/pipelines:main
    container_name: pipelines
    restart: always
    ports: ["9099:9099"]
    volumes:
      - ./pipelines:/app/pipelines
      - pipelines-data:/app/data
    environment:
      - PIPELINES_DIR=/app/pipelines

volumes:
  open-webui-data:
  pipelines-data:
DCOMPOSE

log "8/12 Start Open WebUI & Pipelines"
docker-compose up -d

cat > /etc/systemd/system/open-webui.service <<EOF
[Unit]
Description=Open WebUI
Requires=docker.service
After=docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/open-webui
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable open-webui.service

log "9/12 Wait for services"
for i in {1..30}; do curl -sf http://localhost:8080 >/dev/null 2>&1 && break; sleep 5; log "WebUI... $((i*5))s"; done
for i in {1..30}; do curl -sf http://localhost:9099/ >/dev/null 2>&1 && break; sleep 5; log "Pipelines... $((i*5))s"; done
for i in {1..60}; do curl -sf http://${bedrock_gateway}:8000/health >/dev/null 2>&1 && break; sleep 5; log "Gateway... $((i*5))s"; done

log "10/12 Sync models & setup AD"
sleep 10
docker exec -i open-webui python3 <<'PYEOF' || log "⚠️ Model sync failed"
import os,requests,json,time
from datetime import datetime
os.environ['DATA_DIR']='/app/backend/data'
for i in range(30):
    try:
        from open_webui.internal.db import engine
        from sqlalchemy import text
        break
    except: time.sleep(2)
r=requests.get('http://${bedrock_gateway}:8000/api/tags',timeout=10)
models=r.json()['models']
with engine.connect() as c:
    c.execute(text('DELETE FROM model'))
    for m in models:
        ts=int(datetime.now().timestamp())
        c.execute(text("INSERT INTO model (id,user_id,base_model_id,name,params,meta,created_at,updated_at,is_active,access_control) VALUES (:id,'',:bid,:n,'{}','{}',:ts,:ts,1,NULL)"),{'id':m['model'],'bid':m['model'],'n':m['name'],'ts':ts})
    c.commit()
print(f'Synced {len(models)} models')
PYEOF

log "11/12 Setup AD users"
aws ds enable-directory-data-access --directory-id "${ad_directory_id}" --region ${aws_region} 2>&1 || true
sleep 30

aws ds-data create-user --directory-id "${ad_directory_id}" --sam-account-name Admin --given-name Admin --surname User --email-address "admin@corp.aiportal.local" --region ${aws_region} 2>&1 || true
aws ds-data update-user --directory-id "${ad_directory_id}" --sam-account-name Admin --email-address "admin@corp.aiportal.local" --region ${aws_region} 2>&1 || true
aws ds reset-user-password --directory-id "${ad_directory_id}" --user-name Admin --new-password "${ad_admin_password}" --region ${aws_region} 2>&1 || true

sleep 15

log "Pre-seeding Admin user in Open WebUI database"
docker exec -i open-webui python3 <<'PYEOF' || log "⚠️ Admin pre-seed failed"
import os,time,uuid
from datetime import datetime
os.environ['DATA_DIR']='/app/backend/data'
for i in range(10):
    try:
        from open_webui.internal.db import engine
        from sqlalchemy import text
        break
    except: time.sleep(2)
with engine.connect() as c:
    r=c.execute(text("SELECT id FROM user WHERE email='admin@corp.aiportal.local'"))
    if r.fetchone() is None:
        ts=int(datetime.now().timestamp())
        c.execute(text("INSERT INTO user (id,name,email,role,profile_image_url,created_at,updated_at,last_active_at,api_key,settings,info) VALUES (:id,'Admin','admin@corp.aiportal.local','admin','/user.png',:ts,:ts,:ts,NULL,'{}','{}')"),{'id':str(uuid.uuid4()),'ts':ts})
        print('Admin user pre-seeded with admin role')
    else:
        c.execute(text("UPDATE user SET role='admin' WHERE email='admin@corp.aiportal.local'"))
        print('Admin user updated to admin role')
    c.commit()
PYEOF

log "Assigning admin role to Admin user in Keycloak"
# Get Keycloak admin token
KC_TOKEN=$(curl -sf -X POST "${keycloak_url}/realms/master/protocol/openid-connect/token" \
  -d "username=admin" -d "password=${keycloak_admin_password}" \
  -d "grant_type=password" -d "client_id=admin-cli" | jq -r '.access_token') || true

if [ -n "$KC_TOKEN" ] && [ "$KC_TOKEN" != "null" ]; then
  # Trigger LDAP sync to ensure Admin user exists in Keycloak
  LDAP_ID=$(curl -sf "${keycloak_url}/admin/realms/aiportal/components" \
    -H "Authorization: Bearer $KC_TOKEN" | jq -r '.[]|select(.providerId=="ldap")|.id') || true
  [ -n "$LDAP_ID" ] && curl -sf -X POST "${keycloak_url}/admin/realms/aiportal/user-storage/$LDAP_ID/sync?action=triggerFullSync" \
    -H "Authorization: Bearer $KC_TOKEN" || true
  sleep 10

  # Get Admin user ID and admin role ID
  ADMIN_USER_ID=$(curl -sf "${keycloak_url}/admin/realms/aiportal/users?username=Admin" \
    -H "Authorization: Bearer $KC_TOKEN" | jq -r '.[0].id') || true
  ADMIN_ROLE=$(curl -sf "${keycloak_url}/admin/realms/aiportal/roles/admin" \
    -H "Authorization: Bearer $KC_TOKEN") || true

  # Assign admin role to Admin user
  if [ -n "$ADMIN_USER_ID" ] && [ "$ADMIN_USER_ID" != "null" ] && [ -n "$ADMIN_ROLE" ]; then
    curl -sf -X POST "${keycloak_url}/admin/realms/aiportal/users/$ADMIN_USER_ID/role-mappings/realm" \
      -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
      -d "[$ADMIN_ROLE]" && log "✅ Admin role assigned to Admin user" || log "⚠️ Failed to assign admin role"
  else
    log "⚠️ Could not find Admin user or admin role in Keycloak"
  fi

  # Assign user role to testuser
  TEST_USER_ID=$(curl -sf "${keycloak_url}/admin/realms/aiportal/users?username=testuser" \
    -H "Authorization: Bearer $KC_TOKEN" | jq -r '.[0].id') || true
  USER_ROLE=$(curl -sf "${keycloak_url}/admin/realms/aiportal/roles/user" \
    -H "Authorization: Bearer $KC_TOKEN") || true

  if [ -n "$TEST_USER_ID" ] && [ "$TEST_USER_ID" != "null" ] && [ -n "$USER_ROLE" ]; then
    curl -sf -X POST "${keycloak_url}/admin/realms/aiportal/users/$TEST_USER_ID/role-mappings/realm" \
      -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
      -d "[$USER_ROLE]" && log "✅ User role assigned to testuser" || log "⚠️ Failed to assign user role"
  fi
else
  log "⚠️ Could not get Keycloak token for role assignment"
fi

aws ds-data create-user --directory-id "${ad_directory_id}" --sam-account-name testuser --given-name Test --surname User --email-address "testuser@corp.aiportal.local" --region ${aws_region} 2>&1 || true
aws ds reset-user-password --directory-id "${ad_directory_id}" --user-name testuser --new-password "Welcome@2024" --region ${aws_region} 2>&1 || true

log "Pre-seeding testuser in Open WebUI database with user role"
docker exec -i open-webui python3 <<'PYEOF' || log "⚠️ testuser pre-seed failed"
import os,time,uuid
from datetime import datetime
os.environ['DATA_DIR']='/app/backend/data'
for i in range(10):
    try:
        from open_webui.internal.db import engine
        from sqlalchemy import text
        break
    except: time.sleep(2)
with engine.connect() as c:
    r=c.execute(text("SELECT id FROM user WHERE email='testuser@corp.aiportal.local'"))
    if r.fetchone() is None:
        ts=int(datetime.now().timestamp())
        c.execute(text("INSERT INTO user (id,name,email,role,profile_image_url,created_at,updated_at,last_active_at,api_key,settings,info) VALUES (:id,'Test User','testuser@corp.aiportal.local','user','/user.png',:ts,:ts,:ts,NULL,'{}','{}')"),{'id':str(uuid.uuid4()),'ts':ts})
        print('testuser pre-seeded with user role')
    else:
        print('testuser already exists')
    c.commit()
PYEOF

log "12/12 Done"
log "✅ COMPLETE - ${open_webui_url}"
log "Pipelines: Detoxify, LLM-Guard, Turn Limit (${max_conversation_turns} turns)"
log "Admin: Admin / (AD password), Test: testuser / Welcome@2024"
