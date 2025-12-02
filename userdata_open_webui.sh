#!/bin/bash
# OPEN WEBUI PROVISIONING - Log: /var/log/provisioning.log
exec > >(tee -a /var/log/provisioning.log) 2>&1
set -e
trap 'echo "[OPEN-WEBUI] ❌ FAILED at line $LINENO"' ERR

log() { echo "[OPEN-WEBUI] $(date +%H:%M:%S) $1"; }

log "Starting - Keycloak: ${keycloak_url}, Gateway: ${bedrock_gateway}"

log "1/10 System update"
yum update -y

log "2/10 Install Docker"
yum install -y docker postgresql15
systemctl start docker && systemctl enable docker
usermod -aG docker ec2-user

log "3/10 Install Docker Compose"
curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

log "4/10 Wait for Keycloak (max 10min)"
for i in {1..60}; do curl -sf "${keycloak_url}/realms/master" >/dev/null 2>&1 && break; sleep 10; log "Waiting... $((i*10))s"; done

log "5/10 Create app directory"
mkdir -p /opt/open-webui && cd /opt/open-webui

log "6/10 Create config files"
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
EOF

cat > docker-compose.yml <<'EOF'
version: '3.8'
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: always
    ports: ["8080:8080"]
    volumes: [open-webui-data:/app/backend/data]
    env_file: [.env]
volumes:
  open-webui-data:
EOF

log "7/10 Start Open WebUI"
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

log "8/10 Wait for services"
for i in {1..24}; do curl -sf http://localhost:8080 >/dev/null 2>&1 && break; sleep 5; log "WebUI... $((i*5))s"; done
for i in {1..60}; do curl -sf http://${bedrock_gateway}:8000/health >/dev/null 2>&1 && break; sleep 5; log "Gateway... $((i*5))s"; done

log "9/10 Sync models & setup AD"
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

aws ds enable-directory-data-access --directory-id "${ad_directory_id}" --region ${aws_region} 2>&1 || true
sleep 30

aws ds-data create-user --directory-id "${ad_directory_id}" --sam-account-name Admin --given-name Admin --surname User --email-address "admin@corp.aiportal.local" --region ${aws_region} 2>&1 || true
aws ds-data update-user --directory-id "${ad_directory_id}" --sam-account-name Admin --email-address "admin@corp.aiportal.local" --region ${aws_region} 2>&1 || true
aws ds reset-user-password --directory-id "${ad_directory_id}" --user-name Admin --new-password "${ad_admin_password}" --region ${aws_region} 2>&1 || true

sleep 15
docker exec -i open-webui python3 <<'PYEOF' || log "⚠️ Admin setup failed"
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
        c.execute(text("INSERT INTO user (id,name,email,role,profile_image_url,created_at,updated_at,last_active_at,api_key,settings,info) VALUES (:id,'Admin','admin@corp.aiportal.local','admin','/user.png',0,0,0,NULL,'{}','{}')"),{'id':str(uuid.uuid4())})
    else:
        c.execute(text("UPDATE user SET role='admin' WHERE email='admin@corp.aiportal.local'"))
    c.commit()
print('Admin configured')
PYEOF

aws ds-data create-user --directory-id "${ad_directory_id}" --sam-account-name testuser --given-name Test --surname User --email-address "testuser@corp.aiportal.local" --region ${aws_region} 2>&1 || true
aws ds reset-user-password --directory-id "${ad_directory_id}" --user-name testuser --new-password "Welcome@2024" --region ${aws_region} 2>&1 || true

log "10/10 Done"
log "✅ COMPLETE - ${open_webui_url}"
log "Admin: Admin / (AD password), Test: testuser / Welcome@2024"
