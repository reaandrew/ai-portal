# Grafana Monitoring Stack for OpenWebUI

This is a **separate** Terraform deployment for Grafana + InfluxDB monitoring. It does NOT modify the existing infrastructure - it only reads from it via data sources.

## Architecture

```
                                    ┌─────────────────────────┐
                                    │     Existing ALB        │
                                    │  (ai-portal-alb)        │
                                    └───────────┬─────────────┘
                                                │
                    ┌───────────────────────────┼───────────────────────────┐
                    │                           │                           │
                    ▼                           ▼                           ▼
        ┌───────────────────┐       ┌───────────────────┐       ┌───────────────────┐
        │  portal.openwebui │       │  auth.openwebui   │       │ grafana.openwebui │
        │  (Open WebUI)     │       │  (Keycloak)       │       │ (NEW - Grafana)   │
        └─────────┬─────────┘       └───────────────────┘       └─────────┬─────────┘
                  │                                                       │
                  │  Metrics (InfluxDB line protocol)                     │
                  └───────────────────────────────────────────────────────┘
                                                │
                                                ▼
                                    ┌───────────────────┐
                                    │     InfluxDB      │
                                    │   (on Grafana EC2)│
                                    └───────────────────┘
```

## Prerequisites

1. Existing ai-portal infrastructure deployed
2. AWS credentials configured (`aws-vault exec ee-sso`)
3. Access to Keycloak admin console

## Deployment Steps

### 1. Create Keycloak Client for Grafana

Before deploying, create a client in Keycloak:

1. Go to https://auth.openwebui.demos.apps.equal.expert/admin
2. Select realm: `aiportal`
3. Go to **Clients** → **Create client**
4. Configure:
   - **Client ID**: `grafana`
   - **Client Protocol**: `openid-connect`
   - **Client Authentication**: ON (confidential)
   - **Valid Redirect URIs**: `https://grafana.openwebui.demos.apps.equal.expert/login/generic_oauth`
   - **Web Origins**: `https://grafana.openwebui.demos.apps.equal.expert`
5. Go to **Credentials** tab and copy the **Client Secret**
6. Update `terraform.tfvars` with the client secret

### 2. Deploy the Monitoring Stack

```bash
cd monitoring

# Initialize Terraform
aws-vault exec ee-sso -- terraform init

# Review the plan
aws-vault exec ee-sso -- terraform plan

# Apply
aws-vault exec ee-sso -- terraform apply
```

### 3. Configure OpenWebUI to Send Metrics

The dashboard expects metrics in InfluxDB with the `openwebui_stats` measurement. You have two options:

#### Option A: Add Telegraf to OpenWebUI Instance

SSH to the OpenWebUI instance and add Telegraf:

```bash
# Install Telegraf
sudo dnf install -y telegraf

# Configure Telegraf to collect OpenWebUI metrics
sudo cat > /etc/telegraf/telegraf.conf << 'EOF'
[agent]
  interval = "10s"

[[outputs.influxdb_v2]]
  urls = ["http://<GRAFANA_PRIVATE_IP>:8086"]
  token = "openwebui-metrics-token-change-me"
  organization = "aiportal"
  bucket = "telegraf"

[[inputs.exec]]
  commands = ["/opt/collect_openwebui_metrics.sh"]
  timeout = "5s"
  data_format = "influx"
EOF

sudo systemctl enable telegraf
sudo systemctl start telegraf
```

#### Option B: Custom Metrics Pipeline

Add a custom pipeline filter to OpenWebUI that sends metrics directly to InfluxDB. Create a new filter in `/opt/pipelines/metrics_filter.py`:

```python
from typing import List, Optional
import httpx
import time

class Pipeline:
    class Valves:
        pipelines: List[str] = ["*"]
        influxdb_url: str = "http://<GRAFANA_PRIVATE_IP>:8086"
        influxdb_token: str = "openwebui-metrics-token-change-me"
        influxdb_org: str = "aiportal"
        influxdb_bucket: str = "telegraf"

    def __init__(self):
        self.valves = self.Valves()

    async def outlet(self, body: dict, user: Optional[dict] = None) -> dict:
        model = body.get("model", "unknown")

        # Calculate tokens (simplified - use actual token counts if available)
        messages = body.get("messages", [])
        prompt_tokens = sum(len(m.get("content", "").split()) for m in messages if m.get("role") == "user")
        response_tokens = sum(len(m.get("content", "").split()) for m in messages if m.get("role") == "assistant")

        # Send to InfluxDB
        line = f"openwebui_stats,model={model} promptTokens={prompt_tokens}i,responseTokens={response_tokens}i"

        try:
            async with httpx.AsyncClient() as client:
                await client.post(
                    f"{self.valves.influxdb_url}/api/v2/write",
                    params={"org": self.valves.influxdb_org, "bucket": self.valves.influxdb_bucket},
                    headers={
                        "Authorization": f"Token {self.valves.influxdb_token}",
                        "Content-Type": "text/plain"
                    },
                    content=line
                )
        except Exception as e:
            print(f"Failed to send metrics: {e}")

        return body
```

### 4. Access Grafana

After deployment:
- **URL**: https://grafana.openwebui.demos.apps.equal.expert
- **Login**: Click "Sign in with Keycloak" or use admin credentials

The OpenWebUI dashboard (ID: 22867) will be automatically imported.

## Metrics Expected by Dashboard

The dashboard expects these fields in the `openwebui_stats` measurement:

| Field | Type | Description |
|-------|------|-------------|
| `evalCount` | integer | Evaluation tokens generated |
| `promptEvalCount` | integer | Prompt evaluation tokens |
| `promptTokens` | integer | Input token rate |
| `responseTokens` | integer | Output token rate |
| `approximateTotalMS` | integer | Request duration in ms |

Tags:
- `model` - The model name (e.g., `claude-3-sonnet`, `gpt-4`)

## Troubleshooting

### Check Grafana logs
```bash
ssh -i ~/.ssh/ai-portal-key ec2-user@<GRAFANA_IP>
docker logs grafana
```

### Check InfluxDB
```bash
docker exec -it influxdb influx query 'from(bucket:"telegraf") |> range(start: -1h)'
```

### Test metrics ingestion
```bash
curl -X POST 'http://<GRAFANA_IP>:8086/api/v2/write?org=aiportal&bucket=telegraf' \
  -H 'Authorization: Token openwebui-metrics-token-change-me' \
  -H 'Content-Type: text/plain' \
  --data-binary 'openwebui_stats,model=test promptTokens=100i,responseTokens=50i'
```

## Costs

- t3.small EC2: ~$15/month
- No additional ALB cost (uses existing)
- No additional Route53 cost (uses existing zone)

**Estimated additional cost: ~$15-20/month**
