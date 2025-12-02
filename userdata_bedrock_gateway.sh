#!/bin/bash
# BEDROCK GATEWAY PROVISIONING - Log: /var/log/provisioning.log
exec > >(tee -a /var/log/provisioning.log) 2>&1
set -e
trap 'echo "[BEDROCK-GW] ❌ FAILED at line $LINENO"' ERR

log() { echo "[BEDROCK-GW] $(date +%H:%M:%S) $1"; }

log "Starting - Region: ${aws_region}"

log "1/6 System update"
yum update -y

log "2/6 Install Docker & Python"
yum install -y docker python3 python3-pip git
systemctl start docker && systemctl enable docker
usermod -aG docker ec2-user

log "3/6 Install Docker Compose"
curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

log "4/6 Create app"
mkdir -p /opt/bedrock-gateway && cd /opt/bedrock-gateway

cat > requirements.txt <<EOF
fastapi==0.109.0
uvicorn[standard]==0.27.0
boto3==1.34.34
pydantic==2.6.0
python-dotenv==1.0.1
EOF

cat > main.py <<'PYEOF'
from fastapi import FastAPI, HTTPException, Request
import boto3, os, json
from datetime import datetime

app = FastAPI(title="Bedrock Gateway", version="3.0.0")
bedrock_runtime = boto3.client('bedrock-runtime', region_name=os.getenv('AWS_REGION', 'eu-west-2'))
bedrock_client = boto3.client('bedrock', region_name=os.getenv('AWS_REGION', 'eu-west-2'))
_cache, _time = None, None

def get_models():
    global _cache, _time
    if _cache and _time and (datetime.now() - _time).seconds < 3600: return _cache
    try:
        r = bedrock_client.list_foundation_models()
        models = []
        for m in r.get('modelSummaries', []):
            if m.get('providerName') == 'DeepSeek': continue
            if any(p in m['modelId'].lower() for p in ['deepseek','embed','image']): continue
            it = m.get('inferenceTypesSupported', [])
            if 'CROSS_REGION' in it or 'INFERENCE_PROFILE' in it or 'ON_DEMAND' not in it: continue
            if 'TEXT' in m.get('outputModalities', []):
                models.append({"name": m['modelId'], "model": m['modelId'], "modified_at": datetime.now().isoformat()+"Z", "size": 0, "digest": m['modelName']})
        _cache, _time = models, datetime.now()
        return models
    except Exception as e:
        return [{"name": "anthropic.claude-3-7-sonnet-20250219-v1:0", "model": "anthropic.claude-3-7-sonnet-20250219-v1:0", "modified_at": "2025-02-19T00:00:00Z", "size": 0, "digest": "claude-3-7-sonnet"}]

@app.get("/health")
async def health(): return {"status": "healthy", "service": "bedrock-gateway", "version": "3.0.0"}

@app.get("/api/tags")
async def list_models(): return {"models": get_models()}

@app.get("/api/version")
async def version(): return {"version": "3.0.0"}

@app.post("/api/generate")
async def generate(request: Request):
    data = await request.json()
    r = bedrock_runtime.converse(modelId=data.get("model", "anthropic.claude-sonnet-4-5-20250929-v1:0"), messages=[{"role": "user", "content": [{"text": data.get("prompt", "")}]}], inferenceConfig={"maxTokens": data.get("max_tokens", 2048), "temperature": data.get("temperature", 0.7)})
    text = "".join(c.get('text', '') for c in r.get('output', {}).get('message', {}).get('content', []))
    return {"model": data.get("model"), "created_at": datetime.now().isoformat()+"Z", "response": text, "done": True}

@app.post("/api/chat")
async def chat(request: Request):
    data = await request.json()
    msgs = [{"role": m.get("role", "user"), "content": [{"text": m.get("content", "")}]} for m in data.get("messages", [])]
    r = bedrock_runtime.converse(modelId=data.get("model", "anthropic.claude-sonnet-4-5-20250929-v1:0"), messages=msgs, inferenceConfig={"maxTokens": data.get("max_tokens", 2048), "temperature": data.get("temperature", 0.7)})
    text = "".join(c.get('text', '') for c in r.get('output', {}).get('message', {}).get('content', []))
    return {"model": data.get("model"), "created_at": datetime.now().isoformat()+"Z", "message": {"role": "assistant", "content": text}, "done": True}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
PYEOF

cat > .env <<EOF
AWS_REGION=${aws_region}
EOF

log "5/6 Install dependencies"
pip3 install -r requirements.txt

log "6/6 Create and start service"
cat > /etc/systemd/system/bedrock-gateway.service <<EOF
[Unit]
Description=Bedrock Gateway API
After=network.target
[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/bedrock-gateway
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=/opt/bedrock-gateway/.env
ExecStart=/usr/local/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

chown -R ec2-user:ec2-user /opt/bedrock-gateway
systemctl daemon-reload && systemctl enable bedrock-gateway && systemctl start bedrock-gateway

for i in {1..30}; do curl -sf http://localhost:8000/health >/dev/null 2>&1 && break; sleep 2; log "Waiting... $((i*2))s"; done

log "✅ COMPLETE - http://localhost:8000"
