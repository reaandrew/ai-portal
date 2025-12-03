#!/bin/bash
# LANGFUSE v3 PROVISIONING - Log: /var/log/provisioning.log
# Includes ClickHouse, Redis, and MinIO for full v3 functionality
exec > >(tee -a /var/log/provisioning.log) 2>&1
set -e
trap 'echo "[LANGFUSE] ❌ FAILED at line $LINENO"' ERR

log() { echo "[LANGFUSE] $(date +%H:%M:%S) $1"; }

log "Starting Langfuse v3 - DB: ${db_endpoint}"

log "1/7 System update"
yum update -y

log "2/7 Install Docker"
yum install -y docker postgresql15
systemctl start docker && systemctl enable docker
usermod -aG docker ec2-user

log "3/7 Install Docker Compose"
curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

log "4/7 Create Langfuse database"
export PGPASSWORD="${db_password}"
psql "host=${db_endpoint} port=${db_port} dbname=${db_admin_database} user=${db_username} sslmode=require" -c "CREATE DATABASE ${db_name};" 2>&1 || log "DB may exist"

log "5/7 Create app directory"
mkdir -p /opt/langfuse && cd /opt/langfuse

# Generate keys for Langfuse v3
NEXTAUTH_SECRET=$(openssl rand -base64 32)
SALT=$(openssl rand -base64 16)
ENCRYPTION_KEY=$(openssl rand -hex 32)
CLICKHOUSE_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
REDIS_AUTH=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
MINIO_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')

log "6/7 Create Docker Compose configuration"
cat > docker-compose.yml <<EOF
# Langfuse v3 with ClickHouse, Redis, and MinIO
services:
  # ClickHouse - Analytics database for traces and observations
  clickhouse:
    image: docker.io/clickhouse/clickhouse-server
    container_name: langfuse-clickhouse
    restart: always
    user: "101:101"
    environment:
      CLICKHOUSE_DB: default
      CLICKHOUSE_USER: clickhouse
      CLICKHOUSE_PASSWORD: $CLICKHOUSE_PASSWORD
    volumes:
      - clickhouse_data:/var/lib/clickhouse
      - clickhouse_logs:/var/log/clickhouse-server
    ports:
      - "127.0.0.1:8123:8123"
      - "127.0.0.1:9000:9000"
    healthcheck:
      test: wget --no-verbose --tries=1 --spider http://localhost:8123/ping || exit 1
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 1s

  # MinIO - S3-compatible object storage for events and media
  minio:
    image: cgr.dev/chainguard/minio
    container_name: langfuse-minio
    restart: always
    entrypoint: sh
    command: -c 'mkdir -p /data/langfuse && minio server --address ":9000" --console-address ":9001" /data'
    environment:
      MINIO_ROOT_USER: minio
      MINIO_ROOT_PASSWORD: $MINIO_PASSWORD
    ports:
      - "9090:9000"
      - "127.0.0.1:9091:9001"
    volumes:
      - minio_data:/data
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 1s
      timeout: 5s
      retries: 5
      start_period: 1s

  # Redis - Cache and queue for async processing
  redis:
    image: docker.io/redis:7
    container_name: langfuse-redis
    restart: always
    command: >
      --requirepass $REDIS_AUTH
      --maxmemory-policy noeviction
    ports:
      - "127.0.0.1:6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "$REDIS_AUTH", "ping"]
      interval: 3s
      timeout: 10s
      retries: 10

  # Langfuse Worker - Background job processing
  langfuse-worker:
    image: docker.io/langfuse/langfuse-worker:3
    container_name: langfuse-worker
    restart: always
    depends_on:
      clickhouse:
        condition: service_healthy
      minio:
        condition: service_healthy
      redis:
        condition: service_healthy
    ports:
      - "127.0.0.1:3030:3030"
    environment: &langfuse-env
      # Database - using external RDS PostgreSQL
      DATABASE_URL: postgresql://${db_username}:${db_password}@${db_endpoint}:${db_port}/${db_name}?sslmode=require
      # ClickHouse
      CLICKHOUSE_MIGRATION_URL: clickhouse://clickhouse:9000
      CLICKHOUSE_URL: http://clickhouse:8123
      CLICKHOUSE_USER: clickhouse
      CLICKHOUSE_PASSWORD: $CLICKHOUSE_PASSWORD
      CLICKHOUSE_CLUSTER_ENABLED: "false"
      # Redis
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      REDIS_AUTH: $REDIS_AUTH
      REDIS_TLS_ENABLED: "false"
      # MinIO/S3 - Event storage
      LANGFUSE_S3_EVENT_UPLOAD_BUCKET: langfuse
      LANGFUSE_S3_EVENT_UPLOAD_REGION: auto
      LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID: minio
      LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY: $MINIO_PASSWORD
      LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT: http://minio:9000
      LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE: "true"
      LANGFUSE_S3_EVENT_UPLOAD_PREFIX: events/
      # MinIO/S3 - Media storage (external endpoint for browser uploads)
      LANGFUSE_S3_MEDIA_UPLOAD_BUCKET: langfuse
      LANGFUSE_S3_MEDIA_UPLOAD_REGION: auto
      LANGFUSE_S3_MEDIA_UPLOAD_ACCESS_KEY_ID: minio
      LANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY: $MINIO_PASSWORD
      LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT: ${langfuse_url}:9090
      LANGFUSE_S3_MEDIA_UPLOAD_FORCE_PATH_STYLE: "true"
      LANGFUSE_S3_MEDIA_UPLOAD_PREFIX: media/
      # Core settings
      NEXTAUTH_URL: ${langfuse_url}
      NEXTAUTH_SECRET: $NEXTAUTH_SECRET
      SALT: $SALT
      ENCRYPTION_KEY: $ENCRYPTION_KEY
      TELEMETRY_ENABLED: "false"
      LANGFUSE_ENABLE_EXPERIMENTAL_FEATURES: "true"

  # Langfuse Web - Main application
  langfuse-web:
    image: docker.io/langfuse/langfuse:3
    container_name: langfuse-web
    restart: always
    depends_on:
      clickhouse:
        condition: service_healthy
      minio:
        condition: service_healthy
      redis:
        condition: service_healthy
      langfuse-worker:
        condition: service_started
    ports:
      - "3000:3000"
    environment:
      <<: *langfuse-env
      # Authentication - Keycloak SSO
      AUTH_DISABLE_USERNAME_PASSWORD: "true"
      AUTH_DISABLE_SIGNUP: "true"
      AUTH_KEYCLOAK_CLIENT_ID: langfuse
      AUTH_KEYCLOAK_CLIENT_SECRET: langfuse-secret-change-this
      AUTH_KEYCLOAK_ISSUER: ${keycloak_url}/realms/aiportal
      AUTH_KEYCLOAK_ALLOW_ACCOUNT_LINKING: "true"
      # Headless initialization - auto-create org, project, and API keys
      LANGFUSE_INIT_ORG_ID: aiportal
      LANGFUSE_INIT_ORG_NAME: AI Portal
      LANGFUSE_INIT_PROJECT_ID: openwebui
      LANGFUSE_INIT_PROJECT_NAME: Open WebUI
      LANGFUSE_INIT_PROJECT_PUBLIC_KEY: ${langfuse_public_key}
      LANGFUSE_INIT_PROJECT_SECRET_KEY: ${langfuse_secret_key}
      LANGFUSE_INIT_USER_EMAIL: admin@corp.aiportal.local
      LANGFUSE_INIT_USER_NAME: Admin
      LANGFUSE_INIT_USER_PASSWORD: ${langfuse_init_user_password}

volumes:
  clickhouse_data:
  clickhouse_logs:
  minio_data:
EOF

log "7/7 Start Langfuse v3 stack"
docker-compose up -d

cat > /etc/systemd/system/langfuse.service <<EOF
[Unit]
Description=Langfuse v3
Requires=docker.service
After=docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/langfuse
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable langfuse.service

# Wait for Langfuse to be ready (v3 takes longer due to migrations)
log "Waiting for Langfuse v3 to initialize (this may take 2-3 minutes)..."
for i in {1..90}; do curl -sf http://localhost:3000/api/public/health >/dev/null 2>&1 && break; sleep 5; log "Waiting... $((i*5))s"; done

log "✅ COMPLETE - Langfuse v3 deployed"
log "URL: ${langfuse_url}"
log "Components: ClickHouse, Redis, MinIO, Worker, Web"
log "Organization: AI Portal, Project: Open WebUI (auto-provisioned)"
log "OTEL endpoint: ${langfuse_url}/api/public/otel"
