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

# Install Python and pip
yum install -y python3 python3-pip git

# Create application directory
mkdir -p /opt/bedrock-gateway
cd /opt/bedrock-gateway

# Create a simple Bedrock Gateway using FastAPI
cat > requirements.txt <<EOF
fastapi==0.109.0
uvicorn[standard]==0.27.0
boto3==1.34.34
pydantic==2.6.0
python-dotenv==1.0.1
EOF

cat > main.py <<'PYTHON_EOF'
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
import boto3
import json
import os
from datetime import datetime

app = FastAPI(title="Bedrock Gateway", version="3.0.0")

# Initialize Bedrock client
bedrock_runtime = boto3.client(
    service_name='bedrock-runtime',
    region_name=os.getenv('AWS_REGION', 'eu-west-2')
)

bedrock_client = boto3.client(
    service_name='bedrock',
    region_name=os.getenv('AWS_REGION', 'eu-west-2')
)

# Cache for models (refresh every hour)
_models_cache = None
_cache_time = None

# Exclude these providers/models
EXCLUDED_PROVIDERS = ['DeepSeek']
EXCLUDED_MODEL_PATTERNS = ['deepseek', 'embed', 'image']

def get_available_models():
    """Dynamically fetch available Bedrock models"""
    global _models_cache, _cache_time

    # Use cache if less than 1 hour old
    if _models_cache and _cache_time:
        if (datetime.now() - _cache_time).seconds < 3600:
            return _models_cache

    try:
        # Get ALL models
        response = bedrock_client.list_foundation_models()
        models = []

        for model in response.get('modelSummaries', []):
            # Skip excluded providers
            if model.get('providerName') in EXCLUDED_PROVIDERS:
                continue

            # Skip excluded model patterns (deepseek, embed, image models)
            model_id_lower = model['modelId'].lower()
            if any(pattern in model_id_lower for pattern in EXCLUDED_MODEL_PATTERNS):
                continue

            # Only include pure ON_DEMAND models
            # Exclude if has CROSS_REGION or INFERENCE_PROFILE
            inference_types = model.get('inferenceTypesSupported', [])
            if 'CROSS_REGION' in inference_types:
                continue
            if 'INFERENCE_PROFILE' in inference_types:
                continue
            if 'ON_DEMAND' not in inference_types:
                continue

            # Only include text generation models
            modalities = model.get('outputModalities', [])
            if 'TEXT' in modalities:
                model_id = model['modelId']
                models.append({
                    "name": model_id,
                    "model": model_id,
                    "modified_at": datetime.now().isoformat() + "Z",
                    "size": 0,
                    "digest": model['modelName']
                })

        _models_cache = models
        _cache_time = datetime.now()
        return models
    except Exception as e:
        # Fallback to common ON_DEMAND model if API fails
        print(f"Error fetching models: {e}")
        fallback_model = "anthropic.claude-3-7-sonnet-20250219-v1:0"
        return [
            {
                "name": fallback_model,
                "model": fallback_model,
                "modified_at": "2025-02-19T00:00:00Z",
                "size": 0,
                "digest": "claude-3-7-sonnet"
            }
        ]


@app.get("/health")
async def health_check():
    return {"status": "healthy", "service": "bedrock-gateway", "version": "3.0.0"}

@app.get("/api/tags")
async def list_models():
    """Return available Bedrock models in Ollama-compatible format"""
    return {"models": get_available_models()}

@app.get("/api/version")
async def version():
    """Return version info"""
    return {"version": "3.0.0"}

@app.post("/api/generate")
async def generate(request: Request):
    """Handle Ollama-compatible generate requests"""
    try:
        data = await request.json()
        model_id = data.get("model", "anthropic.claude-sonnet-4-5-20250929-v1:0")
        prompt = data.get("prompt", "")

        print(f"Generate request for model: {model_id}")

        # Use Bedrock Converse API (works with all ON_DEMAND models)
        response = bedrock_runtime.converse(
            modelId=model_id,
            messages=[
                {
                    "role": "user",
                    "content": [{"text": prompt}]
                }
            ],
            inferenceConfig={
                "maxTokens": data.get("max_tokens", 2048),
                "temperature": data.get("temperature", 0.7)
            }
        )

        # Extract response text
        response_text = ""
        if 'output' in response:
            message = response['output'].get('message', {})
            for content in message.get('content', []):
                if 'text' in content:
                    response_text += content['text']

        return {
            "model": model_id,
            "created_at": datetime.now().isoformat() + "Z",
            "response": response_text,
            "done": True
        }

    except Exception as e:
        print(f"Error in generate endpoint: {str(e)}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/chat")
async def chat(request: Request):
    """Handle Ollama-compatible chat requests"""
    try:
        data = await request.json()
        model_id = data.get("model", "anthropic.claude-sonnet-4-5-20250929-v1:0")
        messages = data.get("messages", [])

        print(f"Chat request for model: {model_id}")

        # Convert Ollama messages to Bedrock Converse format
        converse_messages = []
        for msg in messages:
            converse_messages.append({
                "role": msg.get("role", "user"),
                "content": [{"text": msg.get("content", "")}]
            })

        # Use Bedrock Converse API (works with all ON_DEMAND models)
        response = bedrock_runtime.converse(
            modelId=model_id,
            messages=converse_messages,
            inferenceConfig={
                "maxTokens": data.get("max_tokens", 2048),
                "temperature": data.get("temperature", 0.7)
            }
        )

        # Extract response text
        response_text = ""
        if 'output' in response:
            message = response['output'].get('message', {})
            for content in message.get('content', []):
                if 'text' in content:
                    response_text += content['text']

        return {
            "model": model_id,
            "created_at": datetime.now().isoformat() + "Z",
            "message": {
                "role": "assistant",
                "content": response_text
            },
            "done": True
        }

    except Exception as e:
        print(f"Error in chat endpoint: {str(e)}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
PYTHON_EOF

# Create environment file
cat > .env <<EOF
AWS_REGION=${aws_region}
EOF

# Install Python dependencies
pip3 install -r requirements.txt

# Create systemd service
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

# Set proper permissions
chown -R ec2-user:ec2-user /opt/bedrock-gateway

# Enable and start the service
systemctl daemon-reload
systemctl enable bedrock-gateway
systemctl start bedrock-gateway

# Setup log rotation
cat > /etc/logrotate.d/bedrock-gateway <<EOF
/var/log/bedrock-gateway/*.log {
  rotate 7
  daily
  compress
  size=50M
  missingok
  delaycompress
  copytruncate
}
EOF

echo "Bedrock Gateway installation completed successfully!"
