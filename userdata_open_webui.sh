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
yum install -y docker postgresql15 jq python3-pip
pip3 install pyyaml
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
        risk_threshold: float = 0.95

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

# PII detection filter using llm-guard Anonymize scanner
cat > pipelines/pii_filter.py <<'PYEOF'
"""
title: PII Detection Filter
description: Detect and block personal identifiable information (PII)
requirements: llm-guard
"""
from typing import List, Optional
from pydantic import BaseModel

class Pipeline:
    class Valves(BaseModel):
        pipelines: List[str] = ["*"]
        priority: int = 1
        detect_email: bool = True
        detect_phone: bool = True
        detect_ssn: bool = True
        detect_credit_card: bool = True
        detect_ip_address: bool = False

    def __init__(self):
        self.type = "filter"
        self.name = "PII Detection Filter"
        self.valves = self.Valves()
        self.scanner = None

    async def on_startup(self):
        from llm_guard.input_scanners import Anonymize
        from llm_guard.input_scanners.anonymize_helpers import BERT_LARGE_NER_CONF

        # Configure which PII types to detect
        hidden_names = []
        if not self.valves.detect_email:
            hidden_names.append("EMAIL_ADDRESS")
        if not self.valves.detect_phone:
            hidden_names.append("PHONE_NUMBER")
        if not self.valves.detect_ssn:
            hidden_names.append("US_SSN")
        if not self.valves.detect_credit_card:
            hidden_names.append("CREDIT_CARD")
        if not self.valves.detect_ip_address:
            hidden_names.append("IP_ADDRESS")

        self.scanner = Anonymize(
            recognizer_conf=BERT_LARGE_NER_CONF,
            hidden_names=hidden_names,
            threshold=0.5
        )

    async def on_shutdown(self):
        pass

    async def inlet(self, body: dict, user: Optional[dict] = None) -> dict:
        msg = body["messages"][-1]["content"]
        sanitized, is_valid, risk = self.scanner.scan(msg)

        if not is_valid:
            # Determine which PII types were detected
            detected = []
            if "[EMAIL_ADDRESS]" in sanitized:
                detected.append("email")
            if "[PHONE_NUMBER]" in sanitized:
                detected.append("phone number")
            if "[US_SSN]" in sanitized:
                detected.append("SSN")
            if "[CREDIT_CARD]" in sanitized:
                detected.append("credit card")
            if "[IP_ADDRESS]" in sanitized:
                detected.append("IP address")
            if "[PERSON]" in sanitized:
                detected.append("person name")

            pii_types = ", ".join(detected) if detected else "personal information"
            raise Exception(f"PII detected: {pii_types}. Please remove personal data before sending.")

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
        target_user_roles: List[str] = ["user", "admin"]

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

# Langfuse v3 filter - uses start_span API (not trace which doesn't exist in SDK v3)
cat > pipelines/langfuse_filter.py <<'PYEOF'
"""
title: Langfuse Filter Pipeline
requirements: langfuse>=3.0.0
"""
from typing import List, Optional
import os, uuid
from pydantic import BaseModel

class Pipeline:
    class Valves(BaseModel):
        pipelines: List[str] = ["*"]
        priority: int = 0

    def __init__(self):
        self.type = "filter"
        self.name = "Langfuse Filter"
        self.valves = self.Valves()
        self.langfuse = None

    async def on_startup(self):
        from langfuse import Langfuse
        self.langfuse = Langfuse(
            secret_key=os.getenv("LANGFUSE_SECRET_KEY", ""),
            public_key=os.getenv("LANGFUSE_PUBLIC_KEY", ""),
            host=os.getenv("LANGFUSE_HOST", ""),
        )

    async def on_shutdown(self):
        if self.langfuse:
            self.langfuse.flush()

    async def inlet(self, body: dict, user: Optional[dict] = None) -> dict:
        return body

    async def outlet(self, body: dict, user: Optional[dict] = None) -> dict:
        if not self.langfuse:
            return body
        try:
            messages = body.get("messages", [])
            chat_id = body.get("chat_id") or body.get("metadata", {}).get("chat_id") or str(uuid.uuid4())
            user_email = user.get("email", "unknown") if user else "unknown"
            model = body.get("model", "unknown")

            user_msgs = [m for m in messages if m.get("role") == "user"]
            asst_msgs = [m for m in messages if m.get("role") == "assistant"]
            last_user = user_msgs[-1].get("content", "") if user_msgs else ""
            last_asst = asst_msgs[-1] if asst_msgs else {}
            output = last_asst.get("content", "")

            # Extract token usage from assistant message
            usage = None
            info = last_asst.get("usage", {})
            if isinstance(info, dict):
                inp = info.get("prompt_eval_count") or info.get("prompt_tokens") or 0
                out = info.get("eval_count") or info.get("completion_tokens") or 0
                if inp or out:
                    usage = {"input": int(inp), "output": int(out), "unit": "TOKENS"}

            span = self.langfuse.start_span(name="chat", input=last_user, metadata={"user_id": user_email})
            span.update_trace(user_id=user_email, session_id=chat_id, tags=["open-webui"], output=output)

            gen = span.start_generation(name="llm", model=model, input=last_user, output=output, usage=usage)
            gen.end()
            span.end()

            self.langfuse.flush()
        except Exception:
            pass
        return body
PYEOF

# OpenTelemetry Collector config for Langfuse integration
# Compute base64 auth header for OTEL exporter
LANGFUSE_AUTH_BASE64=$(echo -n '${langfuse_public_key}:${langfuse_secret_key}' | base64 -w0)
cat > otel-collector-config.yaml <<OTELEOF
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 1s
    send_batch_size: 1024

exporters:
  otlphttp:
    endpoint: ${langfuse_url}/api/public/otel
    headers:
      Authorization: "Basic $LANGFUSE_AUTH_BASE64"

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlphttp]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlphttp]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlphttp]
OTELEOF

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
ENABLE_OAUTH_GROUP_MANAGEMENT=true
ENABLE_OAUTH_GROUP_CREATION=true
OAUTH_GROUP_CLAIM=groups
ENABLE_WEBSOCKET_SUPPORT=false
EOF

cat > docker-compose.yml <<'DCOMPOSE'
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: always
    ports: ["8080:8080"]
    volumes: [open-webui-data:/app/backend/data]
    env_file: [.env]
    depends_on: [pipelines, otel-collector]
    environment:
      - OPENAI_API_BASE_URL=http://pipelines:9099
      - OPENAI_API_KEY=0p3n-w3bu!
      # OpenTelemetry for Langfuse tracing
      - ENABLE_OTEL=true
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
      - OTEL_SERVICE_NAME=open-webui

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
      - LANGFUSE_SECRET_KEY=${langfuse_secret_key}
      - LANGFUSE_PUBLIC_KEY=${langfuse_public_key}
      - LANGFUSE_HOST=${langfuse_url}

  # OTEL Collector - bridges gRPC to HTTP for Langfuse
  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    container_name: otel-collector
    restart: always
    command: ["--config=/etc/otel-collector-config.yaml"]
    volumes:
      - ./otel-collector-config.yaml:/etc/otel-collector-config.yaml:ro
    ports:
      - "127.0.0.1:4317:4317"
      - "127.0.0.1:4318:4318"

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

log "11/12 Setup AD users from YAML config"
aws ds enable-directory-data-access --directory-id "${ad_directory_id}" --region ${aws_region} 2>&1 || true
sleep 30

# Download AD users config from S3
aws s3 cp s3://${s3_bucket}/ad_users.yaml /tmp/ad_users.yaml --region ${aws_region}

# Setup Admin user (always exists with admin password)
aws ds-data create-user --directory-id "${ad_directory_id}" --sam-account-name Admin --given-name Admin --surname User --email-address "admin@corp.aiportal.local" --region ${aws_region} 2>&1 || true
aws ds-data update-user --directory-id "${ad_directory_id}" --sam-account-name Admin --email-address "admin@corp.aiportal.local" --region ${aws_region} 2>&1 || true
aws ds reset-user-password --directory-id "${ad_directory_id}" --user-name Admin --new-password "${ad_admin_password}" --region ${aws_region} 2>&1 || true

# Parse YAML and create AD groups and users
python3 <<'PYEOF'
import yaml
import subprocess
import sys

DIRECTORY_ID = "${ad_directory_id}"
REGION = "${aws_region}"
DEFAULT_PASSWORD = "SuperInsecure123@"
DOMAIN = "corp.aiportal.local"

def run_aws(cmd):
    """Run AWS CLI command, return True if successful"""
    try:
        subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True)
        return True
    except subprocess.CalledProcessError as e:
        # Ignore "already exists" type errors
        return False

with open('/tmp/ad_users.yaml', 'r') as f:
    config = yaml.safe_load(f)

# Create AD groups
for group in config.get('groups', []):
    print(f"Creating AD group: {group}")
    run_aws(f'aws ds-data create-group --directory-id {DIRECTORY_ID} --sam-account-name "{group}" --region {REGION}')

# Create users
for user in config.get('users', []):
    first_name = user['first_name']
    surname = user['surname']
    username = f"{first_name.lower()}.{surname.lower()}"
    email = f"{username}@{DOMAIN}"
    display_name = f"{first_name} {surname}"

    print(f"Creating AD user: {username} ({email})")

    # Create user
    run_aws(f'aws ds-data create-user --directory-id {DIRECTORY_ID} --sam-account-name "{username}" --given-name "{first_name}" --surname "{surname}" --email-address "{email}" --region {REGION}')

    # Update user (in case they already exist)
    run_aws(f'aws ds-data update-user --directory-id {DIRECTORY_ID} --sam-account-name "{username}" --email-address "{email}" --given-name "{first_name}" --surname "{surname}" --region {REGION}')

    # Set password
    run_aws(f'aws ds reset-user-password --directory-id {DIRECTORY_ID} --user-name "{username}" --new-password "{DEFAULT_PASSWORD}" --region {REGION}')

    # Add to groups
    for group in user.get('groups', []):
        print(f"  Adding {username} to group {group}")
        run_aws(f'aws ds-data add-group-member --directory-id {DIRECTORY_ID} --group-name "{group}" --member-name "{username}" --region {REGION}')

print("AD user setup complete")
PYEOF

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
        c.execute(text("INSERT INTO user (id,name,email,role,profile_image_url,created_at,updated_at,last_active_at,settings,info) VALUES (:id,'Admin','admin@corp.aiportal.local','admin','/user.png',:ts,:ts,:ts,'{}','{}')"),{'id':str(uuid.uuid4()),'ts':ts})
        print('Admin user pre-seeded with admin role')
    else:
        c.execute(text("UPDATE user SET role='admin' WHERE email='admin@corp.aiportal.local'"))
        print('Admin user updated to admin role')
    c.commit()
PYEOF

log "Pre-seeding users from YAML in Open WebUI database"
docker exec -i open-webui python3 <<'PYEOF' || log "⚠️ User pre-seed failed"
import os,time,uuid,yaml
from datetime import datetime
os.environ['DATA_DIR']='/app/backend/data'

# Read the YAML config (mounted or copied)
import subprocess
result = subprocess.run(['cat', '/tmp/ad_users.yaml'], capture_output=True, text=True)
if result.returncode != 0:
    print("Could not read YAML config")
    exit(0)
PYEOF

# Pre-seed users using host Python (has access to YAML file)
python3 <<'PYEOF'
import yaml
import subprocess

DOMAIN = "corp.aiportal.local"

with open('/tmp/ad_users.yaml', 'r') as f:
    config = yaml.safe_load(f)

for user in config.get('users', []):
    first_name = user['first_name']
    surname = user['surname']
    username = f"{first_name.lower()}.{surname.lower()}"
    email = f"{username}@{DOMAIN}"
    display_name = f"{first_name} {surname}"

    # Run pre-seed inside container
    script = f'''
import os,time,uuid
from datetime import datetime
os.environ["DATA_DIR"]="/app/backend/data"
for i in range(10):
    try:
        from open_webui.internal.db import engine
        from sqlalchemy import text
        break
    except: time.sleep(2)
with engine.connect() as c:
    r=c.execute(text("SELECT id FROM user WHERE email=:email"),{{"email":"{email}"}})
    if r.fetchone() is None:
        ts=int(datetime.now().timestamp())
        c.execute(text("INSERT INTO user (id,name,email,role,profile_image_url,created_at,updated_at,last_active_at,settings,info) VALUES (:id,:name,:email,\\'user\\',\\'/user.png\\',:ts,:ts,:ts,\\'{{}}\\',\\'{{}}\\')"),{{"id":str(uuid.uuid4()),"name":"{display_name}","email":"{email}","ts":ts}})
        print(f"Pre-seeded {email} with user role")
    else:
        print(f"{email} already exists")
    c.commit()
'''
    subprocess.run(['docker', 'exec', '-i', 'open-webui', 'python3', '-c', script], capture_output=True)
    print(f"Pre-seeded: {email}")

print("Open WebUI user pre-seed complete")
PYEOF

log "Assigning Keycloak roles to users"
KC_TOKEN=$(curl -sf -X POST "${keycloak_url}/realms/master/protocol/openid-connect/token" \
  -d "username=admin" -d "password=${keycloak_admin_password}" \
  -d "grant_type=password" -d "client_id=admin-cli" | jq -r '.access_token') || true

if [ -n "$KC_TOKEN" ] && [ "$KC_TOKEN" != "null" ]; then
  # Trigger LDAP sync to ensure users exist in Keycloak
  LDAP_ID=$(curl -sf "${keycloak_url}/admin/realms/aiportal/components" \
    -H "Authorization: Bearer $KC_TOKEN" | jq -r '.[]|select(.providerId=="ldap")|.id' | head -1) || true
  [ -n "$LDAP_ID" ] && curl -sf -X POST "${keycloak_url}/admin/realms/aiportal/user-storage/$LDAP_ID/sync?action=triggerFullSync" \
    -H "Authorization: Bearer $KC_TOKEN" || true
  sleep 15

  # Assign admin role to Admin user (retry up to 10 times with longer waits)
  ADMIN_ROLE=$(curl -sf "${keycloak_url}/admin/realms/aiportal/roles/admin" \
    -H "Authorization: Bearer $KC_TOKEN") || true

  ADMIN_ROLE_ASSIGNED=false
  for attempt in {1..10}; do
    # Trigger LDAP sync on each attempt to ensure user is present
    [ -n "$LDAP_ID" ] && curl -sf -X POST "${keycloak_url}/admin/realms/aiportal/user-storage/$LDAP_ID/sync?action=triggerFullSync" \
      -H "Authorization: Bearer $KC_TOKEN" >/dev/null 2>&1 || true
    sleep 5

    ADMIN_USER_ID=$(curl -sf "${keycloak_url}/admin/realms/aiportal/users?username=Admin" \
      -H "Authorization: Bearer $KC_TOKEN" | jq -r '.[0].id') || true

    if [ -n "$ADMIN_USER_ID" ] && [ "$ADMIN_USER_ID" != "null" ] && [ -n "$ADMIN_ROLE" ]; then
      if curl -sf -X POST "${keycloak_url}/admin/realms/aiportal/users/$ADMIN_USER_ID/role-mappings/realm" \
        -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
        -d "[$ADMIN_ROLE]"; then
        log "✅ Admin role assigned to Admin user in Keycloak (attempt $attempt)"
        ADMIN_ROLE_ASSIGNED=true
        break
      else
        log "⚠️ Attempt $attempt: Failed to assign admin role via API"
      fi
    else
      log "⚠️ Attempt $attempt: Admin user not found in Keycloak yet (LDAP sync pending), waiting..."
    fi
    sleep 15
  done

  if [ "$ADMIN_ROLE_ASSIGNED" = false ]; then
    log "❌ WARNING: Could not assign admin role in Keycloak after 10 attempts"
  fi

  # Get user role for all other users
  USER_ROLE=$(curl -sf "${keycloak_url}/admin/realms/aiportal/roles/user" \
    -H "Authorization: Bearer $KC_TOKEN") || true

  # Assign user role to all users from YAML
  python3 <<PYEOF
import yaml
import subprocess
import os

KC_TOKEN = "$KC_TOKEN"
KC_URL = "${keycloak_url}"
USER_ROLE = '''$USER_ROLE'''

with open('/tmp/ad_users.yaml', 'r') as f:
    config = yaml.safe_load(f)

for user in config.get('users', []):
    first_name = user['first_name']
    surname = user['surname']
    username = f"{first_name.lower()}.{surname.lower()}"

    # Get user ID from Keycloak
    result = subprocess.run([
        'curl', '-sf', f'{KC_URL}/admin/realms/aiportal/users?username={username}',
        '-H', f'Authorization: Bearer {KC_TOKEN}'
    ], capture_output=True, text=True)

    import json
    try:
        users = json.loads(result.stdout)
        if users and len(users) > 0:
            user_id = users[0]['id']
            # Assign user role
            subprocess.run([
                'curl', '-sf', '-X', 'POST',
                f'{KC_URL}/admin/realms/aiportal/users/{user_id}/role-mappings/realm',
                '-H', f'Authorization: Bearer {KC_TOKEN}',
                '-H', 'Content-Type: application/json',
                '-d', f'[{USER_ROLE}]'
            ], capture_output=True)
            print(f"Assigned user role to {username}")
    except:
        print(f"Could not assign role to {username}")
PYEOF
else
  log "⚠️ Could not get Keycloak token for role assignment"
fi

log "12/12 Setting up Grafana metrics collection"
# Only set up metrics if InfluxDB URL is configured
if [ -n "${influxdb_url}" ]; then
mkdir -p /opt/metrics
cat > /opt/metrics/openwebui_metrics.sh << 'METRICSSCRIPT'
#!/bin/bash
# OpenWebUI Metrics Collector - sends usage data to InfluxDB with AD group filtering
# Environment variables INFLUX_URL, INFLUX_TOKEN, INFLUX_ORG, INFLUX_BUCKET are set by systemd

DB_PATH="/tmp/webui.db"
docker cp open-webui:/app/backend/data/webui.db "$DB_PATH" 2>/dev/null || exit 1

python3 << 'PYTHON'
import sqlite3, requests, json, os

conn = sqlite3.connect("/tmp/webui.db")
conn.row_factory = sqlite3.Row
cursor = conn.cursor()

# Build user -> group mapping
user_groups = {}
cursor.execute("""
    SELECT u.id, u.email, u.name, g.name as group_name
    FROM user u LEFT JOIN group_member gm ON u.id = gm.user_id
    LEFT JOIN "group" g ON gm.group_id = g.id
""")
for row in cursor.fetchall():
    user_groups[row['id']] = {'email': row['email'], 'name': row['name'], 'group': row['group_name'] or 'Unknown'}

# Get recent chat messages with usage stats
cursor.execute("SELECT id, user_id, chat, updated_at FROM chat WHERE updated_at > (strftime('%s', 'now') - 86400)")

lines = []
for chat in cursor.fetchall():
    user_info = user_groups.get(chat['user_id'], {'email': 'unknown', 'group': 'Unknown'})
    user_group = user_info['group'].replace(' ', '_')
    user_email = user_info['email'].split('@')[0].replace('.', '_')

    try:
        chat_data = json.loads(chat['chat']) if chat['chat'] else {}
        messages = chat_data.get('history', {}).get('messages', {})
        for msg_id, msg in messages.items():
            if isinstance(msg, dict) and 'usage' in msg:
                usage = msg.get('usage', {})
                model = str(msg.get('model', 'unknown')).replace(':', '_').replace(' ', '_')
                prompt_tokens = usage.get('prompt_eval_count', usage.get('prompt_tokens', 0)) or 0
                completion_tokens = usage.get('eval_count', usage.get('completion_tokens', 0)) or 0
                if prompt_tokens > 0 or completion_tokens > 0:
                    ts = msg.get('timestamp', chat['updated_at'])
                    lines.append(f'chat_usage,user={user_email},user_group={user_group},model={model} prompt_tokens={prompt_tokens}i,completion_tokens={completion_tokens}i,total_tokens={prompt_tokens + completion_tokens}i {ts}')
    except: pass

conn.close()

if lines:
    resp = requests.post(
        f"{os.environ.get('INFLUX_URL', 'http://localhost:8086')}/api/v2/write",
        params={"org": os.environ.get('INFLUX_ORG', 'aiportal'), "bucket": os.environ.get('INFLUX_BUCKET', 'openwebui'), "precision": "s"},
        headers={"Authorization": f"Token {os.environ.get('INFLUX_TOKEN', '')}", "Content-Type": "text/plain"},
        data='\n'.join(lines)
    )
    print(f"Sent {len(lines)} metrics: {resp.status_code}")
PYTHON
METRICSSCRIPT
chmod +x /opt/metrics/openwebui_metrics.sh

# Create systemd timer to run every 5 minutes
cat > /etc/systemd/system/openwebui-metrics.service << SVCEOF
[Unit]
Description=OpenWebUI Metrics Collector
After=docker.service
[Service]
Type=oneshot
Environment="INFLUX_URL=${influxdb_url}"
Environment="INFLUX_TOKEN=${influxdb_token}"
Environment="INFLUX_ORG=${influxdb_org}"
Environment="INFLUX_BUCKET=${influxdb_bucket}"
ExecStart=/opt/metrics/openwebui_metrics.sh
SVCEOF

cat > /etc/systemd/system/openwebui-metrics.timer << 'TIMEREOF'
[Unit]
Description=Run OpenWebUI metrics every 5 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
TIMEREOF

systemctl daemon-reload
systemctl enable --now openwebui-metrics.timer
log "Grafana Metrics: Enabled → InfluxDB (every 5 min, with AD group tags)"
else
log "Grafana Metrics: Disabled (influxdb_url not configured)"
fi

log "FINAL FAILSAFE: Forcing Admin role in database"
# This is the NUCLEAR option - force admin role regardless of OAuth or anything else
for i in {1..5}; do
  docker exec -i open-webui python3 <<'PYEOF' && break || sleep 10
import os,time
os.environ['DATA_DIR']='/app/backend/data'
for i in range(30):
    try:
        from open_webui.internal.db import engine
        from sqlalchemy import text
        break
    except: time.sleep(2)
with engine.connect() as c:
    # Force admin role for Admin user (case-insensitive email match)
    result = c.execute(text("UPDATE user SET role='admin' WHERE LOWER(email) LIKE '%admin%'"))
    c.commit()
    # Verify
    r = c.execute(text("SELECT email, role FROM user WHERE LOWER(email) LIKE '%admin%'"))
    for row in r:
        print(f"VERIFIED: {row[0]} has role={row[1]}")
PYEOF
done

# Create startup script that ensures admin role on every boot
cat > /opt/open-webui/ensure_admin.sh <<'ADMINSCRIPT'
#!/bin/bash
# Ensure Admin user has admin role - runs on every boot
sleep 30  # Wait for containers to be ready
docker exec -i open-webui python3 <<'PYEOF'
import os,time
os.environ['DATA_DIR']='/app/backend/data'
for i in range(30):
    try:
        from open_webui.internal.db import engine
        from sqlalchemy import text
        break
    except: time.sleep(2)
with engine.connect() as c:
    c.execute(text("UPDATE user SET role='admin' WHERE LOWER(email) LIKE '%admin%'"))
    c.commit()
    print("Admin role enforced")
PYEOF
ADMINSCRIPT
chmod +x /opt/open-webui/ensure_admin.sh

# Create systemd service to run on boot
cat > /etc/systemd/system/ensure-admin.service <<EOF
[Unit]
Description=Ensure Admin user has admin role
After=docker.service open-webui.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/opt/open-webui/ensure_admin.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ensure-admin.service

log "✅ COMPLETE - ${open_webui_url}"
log "Pipelines: Detoxify, LLM-Guard, PII Detection, Turn Limit (${max_conversation_turns} turns)"
log "OTEL Tracing: Enabled → Langfuse via OTEL Collector"
log "Admin: Admin / (AD password) - ROLE ENFORCED"
log "Users: firstname.surname / TestOpenWebUI123@ (see /tmp/ad_users.yaml)"
