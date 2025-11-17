#!/bin/bash
# Sync models from Bedrock Gateway to Open WebUI
# This populates the model table so users can see available models

set -e

WEBUI_IP=${1:-$(terraform output -raw open_webui_public_ip 2>/dev/null)}
GATEWAY_IP=$(terraform output -raw bedrock_gateway_private_ip 2>/dev/null || echo "10.0.0.73")

if [ -z "$WEBUI_IP" ]; then
    echo "Usage: $0 [open_webui_ip]"
    echo "Or run from terraform directory where output is available"
    exit 1
fi

echo "Syncing models from Bedrock Gateway to Open WebUI at $WEBUI_IP..."

ssh -o StrictHostKeyChecking=no ec2-user@$WEBUI_IP "sudo docker exec -i open-webui python3 <<PYTHON_EOF
import os
import requests
import json
from datetime import datetime

os.environ['DATA_DIR'] = '/app/backend/data'
from open_webui.internal.db import engine
from sqlalchemy import text

# Get models from Bedrock Gateway
print('Fetching models from Bedrock Gateway...')
response = requests.get('http://$GATEWAY_IP:8000/api/tags', timeout=10)
response.raise_for_status()
models_data = response.json()['models']
print(f'✅ Found {len(models_data)} models')

with engine.connect() as conn:
    # Clear existing models
    conn.execute(text('DELETE FROM model'))
    print('Cleared existing model table')

    # Insert models with NULL access_control (= available to all users)
    for model in models_data:
        model_id = model['model']
        created_at = int(datetime.now().timestamp())

        conn.execute(
            text('''
                INSERT INTO model (id, user_id, base_model_id, name, params, meta, created_at, updated_at, is_active, access_control)
                VALUES (:id, '', :base_model_id, :name, '{}', :meta, :created_at, :updated_at, 1, NULL)
            '''),
            {
                'id': model_id,
                'base_model_id': model_id,
                'name': model['name'],
                'meta': json.dumps({'description': model.get('digest', '')}),
                'created_at': created_at,
                'updated_at': created_at
            }
        )

    conn.commit()

    # Verify
    result = conn.execute(text('SELECT COUNT(*) FROM model WHERE is_active = 1'))
    count = result.fetchone()[0]
    print(f'✅ Successfully synced {count} models')
    print('\\nModels are now visible in Open WebUI!')
PYTHON_EOF
"

echo ""
echo "✅ Model sync complete!"
echo "Models should now be visible at http://$WEBUI_IP:8080"
