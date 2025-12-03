# AI Portal Scaling Architecture

This document outlines the considerations, challenges, and implementation approaches for scaling the AI Portal infrastructure to handle increased load and provide high availability.

## Current Architecture (Single Instance)

The current deployment uses single EC2 instances for each component:

```
                            ┌─────────────────────────────────────────┐
                            │           Open WebUI Instance           │
                            │  ┌─────────────┐  ┌─────────────────┐  │
Internet → ALB ─────────────┤  │  Open WebUI │  │    Pipelines    │  │
              │             │  │  Container  │→ │    Container    │  │
              │             │  └─────────────┘  └─────────────────┘  │
              │             └─────────────────────────────────────────┘
              │                                        │
              │             ┌──────────────────────────┼──────────────┐
              │             │                          ▼              │
              ├─────────────┤  Bedrock Gateway Instance               │
              │             │  (FastAPI → AWS Bedrock API)            │
              │             └─────────────────────────────────────────┘
              │
              │             ┌─────────────────────────────────────────┐
              ├─────────────┤  Keycloak Instance                      │
              │             │  (Identity Provider + LDAP Federation)  │
              │             └─────────────────────────────────────────┘
              │
              │             ┌─────────────────────────────────────────┐
              └─────────────┤  Langfuse Instance                      │
                            │  ┌────────┐ ┌─────┐ ┌───────────────┐   │
                            │  │ Web    │ │Redis│ │  ClickHouse   │   │
                            │  │ Worker │ │     │ │  MinIO        │   │
                            │  └────────┘ └─────┘ └───────────────┘   │
                            └─────────────────────────────────────────┘
                                               │
                                               ▼
                            ┌─────────────────────────────────────────┐
                            │  RDS PostgreSQL (Multi-DB)              │
                            │  - aiportal (Open WebUI)                │
                            │  - keycloak                             │
                            │  - langfuse                             │
                            └─────────────────────────────────────────┘
                                               │
                                               ▼
                            ┌─────────────────────────────────────────┐
                            │  AWS Managed Microsoft AD               │
                            │  (corp.aiportal.local)                  │
                            └─────────────────────────────────────────┘
```

### Current Limitations

| Limitation | Impact |
|------------|--------|
| Single point of failure | Any instance failure causes service outage |
| No horizontal scaling | Cannot handle traffic spikes |
| Limited throughput | Bedrock API rate limits per instance |
| Cold start on restart | ML models in Pipelines need reload time |
| No geographic distribution | High latency for distant users |

---

## Component Scaling Analysis

### 1. Bedrock Gateway

**Scaling Difficulty: 🟢 Easy**

The Bedrock Gateway is a stateless FastAPI application that proxies requests to AWS Bedrock. It's the easiest component to scale.

**Why it's easy:**
- Completely stateless - no session data, no local storage
- Each request is independent
- AWS Bedrock handles the actual model inference
- No shared state between instances

**Scaling approach:**
```hcl
# Auto Scaling Group for Bedrock Gateway
resource "aws_autoscaling_group" "bedrock_gateway" {
  name                = "bedrock-gateway-asg"
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.bedrock_gateway.arn]

  min_size         = 2
  max_size         = 10
  desired_capacity = 2

  launch_template {
    id      = aws_launch_template.bedrock_gateway.id
    version = "$Latest"
  }

  health_check_type         = "ELB"
  health_check_grace_period = 300
}

# Scaling policy based on CPU
resource "aws_autoscaling_policy" "bedrock_gateway_cpu" {
  name                   = "bedrock-gateway-cpu-scaling"
  autoscaling_group_name = aws_autoscaling_group.bedrock_gateway.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}
```

**Considerations:**
- Use an internal NLB (Network Load Balancer) for lower latency
- Consider scaling based on request count rather than CPU
- AWS Bedrock has account-level rate limits - scaling instances doesn't bypass these
- May need to request Bedrock quota increases for high-volume usage

**Estimated effort:** 1 day

---

### 2. Langfuse (Observability)

**Scaling Difficulty: 🟢 Easy**

Langfuse v3 is designed for horizontal scaling with its architecture separating web, worker, and storage components.

**Why it's easy:**
- Web and Worker containers are stateless
- State is externalized to ClickHouse, Redis, and S3/MinIO
- Official Helm charts support horizontal pod autoscaling
- No sticky sessions required

**Current single-instance setup:**
```
Langfuse Instance
├── langfuse-web (port 3000)
├── langfuse-worker (background jobs)
├── ClickHouse (analytics DB)
├── Redis (cache/queue)
└── MinIO (object storage)
```

**Scaled architecture:**
```
                    ┌─→ Langfuse Web 1 ─┐
ALB ────────────────┼─→ Langfuse Web 2 ─┼───┐
                    └─→ Langfuse Web N ─┘   │
                                            │
                    ┌─→ Langfuse Worker 1 ──┤
Background Jobs ────┼─→ Langfuse Worker 2 ──┼───┐
                    └─→ Langfuse Worker N ──┘   │
                                                │
                    ┌───────────────────────────┘
                    │
                    ▼
    ┌───────────────────────────────────────────┐
    │         Shared Storage Layer              │
    │  ┌─────────────┐  ┌──────────────────┐   │
    │  │ ElastiCache │  │   S3 Bucket      │   │
    │  │   (Redis)   │  │ (replaces MinIO) │   │
    │  └─────────────┘  └──────────────────┘   │
    │  ┌─────────────────────────────────────┐ │
    │  │  ClickHouse Cluster (or managed)   │ │
    │  └─────────────────────────────────────┘ │
    └───────────────────────────────────────────┘
                    │
                    ▼
    ┌───────────────────────────────────────────┐
    │         RDS PostgreSQL Multi-AZ           │
    └───────────────────────────────────────────┘
```

**Key changes for scaling:**

1. **Replace MinIO with S3:**
   ```bash
   # Environment variables
   LANGFUSE_S3_EVENT_UPLOAD_BUCKET=langfuse-events-prod
   LANGFUSE_S3_EVENT_UPLOAD_REGION=eu-west-2
   # Remove ENDPOINT to use real S3
   ```

2. **Use ElastiCache for Redis:**
   ```hcl
   resource "aws_elasticache_cluster" "langfuse" {
     cluster_id           = "langfuse-redis"
     engine               = "redis"
     node_type            = "cache.t3.micro"
     num_cache_nodes      = 1
     parameter_group_name = "default.redis7"
     port                 = 6379
     security_group_ids   = [aws_security_group.redis.id]
     subnet_group_name    = aws_elasticache_subnet_group.main.name
   }
   ```

3. **ClickHouse options:**
   - Self-managed cluster (complex)
   - ClickHouse Cloud (managed, recommended for production)
   - Single instance with larger disk (acceptable for moderate scale)

**Estimated effort:** 2-3 days

---

### 3. Keycloak (Identity Provider)

**Scaling Difficulty: 🟡 Medium**

Keycloak can scale horizontally but requires careful configuration for session management.

**Challenges:**
- User sessions are stored in memory by default
- Distributed cache (Infinispan) needed for multi-instance
- Database contention with many concurrent logins
- LDAP connection pooling considerations

**Single instance (current):**
```
ALB → Keycloak (standalone) → RDS PostgreSQL
                            → AWS Managed AD (LDAP)
```

**Scaled architecture:**
```
                    ┌─→ Keycloak 1 ─┐
ALB ────────────────┤               ├──→ Infinispan Cache
(sticky sessions)   └─→ Keycloak 2 ─┘    (distributed sessions)
                           │
                           ▼
                    RDS PostgreSQL
                    (Multi-AZ)
                           │
                           ▼
                    AWS Managed AD
```

**Keycloak clustering options:**

1. **Sticky Sessions (simpler):**
   ```hcl
   resource "aws_lb_target_group" "keycloak" {
     # ...
     stickiness {
       type            = "lb_cookie"
       cookie_duration = 86400
       enabled         = true
     }
   }
   ```

   Pros: Simple, no distributed cache needed
   Cons: Session lost if instance dies, uneven load distribution

2. **Distributed Cache (production-grade):**
   ```yaml
   # Keycloak configuration for clustering
   KC_CACHE=ispn
   KC_CACHE_STACK=kubernetes  # or tcp for EC2
   JAVA_OPTS=-Djgroups.dns.query=keycloak-headless.default.svc.cluster.local
   ```

   Pros: True HA, session survives instance failure
   Cons: More complex, requires JGroups/Infinispan configuration

**Database considerations:**
- Enable connection pooling (PgBouncer recommended)
- Consider read replicas for authentication queries
- Index optimization for large user bases

**Estimated effort:** 2-3 days (sticky sessions) or 1 week (distributed cache)

---

### 4. Open WebUI

**Scaling Difficulty: 🔴 Hard**

Open WebUI is the most challenging component to scale due to its stateful nature.

**Why it's hard:**

1. **Local file storage:**
   - User uploads stored in `/app/backend/data`
   - Profile images, documents, attachments
   - Not shared between instances by default

2. **In-memory state:**
   - Active chat sessions tied to instance
   - Model loading state
   - WebSocket connections (though we disabled this)

3. **Database state:**
   - Already using PostgreSQL ✓
   - But file references point to local paths

4. **Pipeline container coupling:**
   - Pipelines container runs alongside Open WebUI
   - ML models loaded in memory (cold start ~30-60s)
   - Sidecar pattern complicates scaling

**Current architecture (tightly coupled):**
```
┌─────────────────────────────────────────────────┐
│  Open WebUI Instance                            │
│  ┌──────────────────┐  ┌─────────────────────┐ │
│  │   Open WebUI     │  │     Pipelines       │ │
│  │   Container      │→ │     Container       │ │
│  │                  │  │ - Detoxify (ML)     │ │
│  │ /app/backend/data│  │ - LLM-Guard (ML)    │ │
│  │ (local volume)   │  │ - Langfuse Filter   │ │
│  └──────────────────┘  │ - Turn Limit        │ │
│                        └─────────────────────┘ │
└─────────────────────────────────────────────────┘
```

**Scaled architecture (decoupled):**
```
                         ┌─→ Open WebUI 1 ─┐
ALB ─────────────────────┼─→ Open WebUI 2 ─┼──→ EFS Mount
  (sticky sessions)      └─→ Open WebUI N ─┘    (/app/backend/data)
                                │                     │
                                ▼                     │
                         ElastiCache Redis ◄──────────┘
                         (session store)
                                │
                                ▼
                         ┌─→ Pipelines 1 ──┐
                    NLB ─┼─→ Pipelines 2 ──┼──→ Warm pool
                         └─→ Pipelines N ──┘   (pre-loaded models)
                                │
                                ▼
                         RDS PostgreSQL Multi-AZ
```

**Required changes for scaling:**

1. **Shared file storage with EFS:**
   ```hcl
   resource "aws_efs_file_system" "open_webui" {
     creation_token = "open-webui-data"
     encrypted      = true

     lifecycle_policy {
       transition_to_ia = "AFTER_30_DAYS"
     }
   }

   resource "aws_efs_mount_target" "open_webui" {
     count           = length(aws_subnet.private)
     file_system_id  = aws_efs_file_system.open_webui.id
     subnet_id       = aws_subnet.private[count.index].id
     security_groups = [aws_security_group.efs.id]
   }
   ```

   Mount in userdata:
   ```bash
   yum install -y amazon-efs-utils
   mkdir -p /mnt/efs/open-webui-data
   mount -t efs ${efs_id}:/ /mnt/efs/open-webui-data

   # Docker volume
   docker run -v /mnt/efs/open-webui-data:/app/backend/data ...
   ```

2. **Session storage with Redis:**
   ```python
   # Open WebUI would need modification to support Redis sessions
   # Currently uses local session storage
   # This would require contributing to the Open WebUI project
   ```

3. **Decouple Pipelines service:**
   ```yaml
   # Separate deployment for Pipelines
   # Accessed via internal NLB
   services:
     pipelines:
       # Run independently with its own scaling
       deploy:
         replicas: 3
       environment:
         - PIPELINES_URLS=  # Pre-load models at startup
   ```

4. **Sticky sessions (ALB):**
   ```hcl
   resource "aws_lb_target_group" "open_webui" {
     # ...
     stickiness {
       type            = "lb_cookie"
       cookie_duration = 3600  # 1 hour
       enabled         = true
     }
   }
   ```

**Pipeline cold start mitigation:**
- Use warm pools in ASG to keep pre-initialized instances ready
- Implement health checks that wait for model loading
- Consider pre-warming with synthetic requests

```hcl
resource "aws_autoscaling_group" "pipelines" {
  # ...

  warm_pool {
    pool_state                  = "Stopped"
    min_size                    = 1
    max_group_prepared_capacity = 3
  }
}
```

**Estimated effort:** 1-2 weeks

---

## Phased Implementation Plan

### Phase 1: Quick Wins (1-2 days)

**Goal:** Scale stateless components for better throughput

1. **Bedrock Gateway ASG**
   - Create launch template from current userdata
   - Configure ASG with 2-4 instances
   - Add internal NLB
   - Update Open WebUI to use NLB endpoint

2. **RDS Multi-AZ**
   ```hcl
   resource "aws_db_instance" "postgres" {
     # ...
     multi_az = true  # Add this
   }
   ```

**Result:** Better Bedrock API throughput, database HA

### Phase 2: Observability Scaling (2-3 days)

**Goal:** Scale Langfuse for high-volume tracing

1. Replace MinIO with S3
2. Add ElastiCache Redis cluster
3. Create Langfuse ASG for web/worker
4. Consider ClickHouse Cloud for managed analytics

**Result:** Handle millions of traces, faster dashboards

### Phase 3: Identity Provider HA (2-3 days)

**Goal:** Keycloak high availability

1. Enable ALB sticky sessions
2. Add second Keycloak instance
3. Configure database connection pooling
4. Test failover scenarios

**Result:** Authentication survives instance failure

### Phase 4: Full Horizontal Scaling (1-2 weeks)

**Goal:** Scale Open WebUI horizontally

1. Provision EFS for shared storage
2. Add ElastiCache for sessions (may require Open WebUI changes)
3. Decouple Pipelines to separate ASG
4. Configure warm pools for Pipelines
5. Implement comprehensive health checks
6. Load testing and tuning

**Result:** True horizontal scaling for all components

---

## Cost Comparison

### Current Single-Instance Costs (Estimated Monthly)

| Component | Instance Type | Cost |
|-----------|---------------|------|
| Open WebUI | t3.large | $60 |
| Bedrock Gateway | t3.large | $60 |
| Keycloak | t3.small | $15 |
| Langfuse | t3.medium | $30 |
| RDS PostgreSQL | db.t3.medium | $50 |
| AWS Managed AD | Standard | $100 |
| ALB | - | $20 |
| NAT Gateway | - | $35 |
| **Total** | | **~$370/month** |

### Scaled Architecture Costs (Estimated Monthly)

| Component | Configuration | Cost |
|-----------|---------------|------|
| Open WebUI (x2) | t3.large | $120 |
| Pipelines (x2) | t3.large | $120 |
| Bedrock Gateway (x2-4) | t3.medium | $60-120 |
| Keycloak (x2) | t3.small | $30 |
| Langfuse Web/Worker (x2) | t3.small | $30 |
| EFS | 50GB | $15 |
| ElastiCache Redis | cache.t3.micro | $15 |
| RDS Multi-AZ | db.t3.medium | $100 |
| S3 (Langfuse) | 100GB | $3 |
| AWS Managed AD | Standard | $100 |
| ALB | - | $25 |
| NLB (internal) | - | $20 |
| NAT Gateway | - | $35 |
| **Total** | | **~$670-730/month** |

### Cost Optimization Strategies

1. **Reserved Instances:** Up to 40% savings for 1-year commitment
2. **Spot Instances:** Use for Pipelines warm pool (70% savings)
3. **Scheduled Scaling:** Scale down during off-hours
4. **Right-sizing:** Start with t3.small, scale up as needed

---

## Monitoring and Alerting

Scaling requires proper observability:

### Key Metrics to Monitor

```hcl
# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "open-webui-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "CPU utilization exceeds 80%"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
```

### Recommended Dashboards

1. **Request Metrics:**
   - Requests per second (by component)
   - Response time percentiles (p50, p95, p99)
   - Error rates (4xx, 5xx)

2. **Resource Metrics:**
   - CPU utilization per instance
   - Memory utilization
   - Disk I/O (especially EFS)
   - Network throughput

3. **Application Metrics:**
   - Active users (from Keycloak)
   - LLM requests per minute
   - Pipeline filter latency
   - Langfuse trace ingestion rate

4. **Cost Metrics:**
   - Bedrock token usage
   - Instance hours by type
   - Data transfer costs

---

## Alternative Architectures

### Container Orchestration (EKS/ECS)

For organizations already using Kubernetes or ECS:

```
                    ┌─────────────────────────────────────┐
                    │            EKS Cluster              │
                    │  ┌─────────────────────────────┐   │
Internet → ALB ─────┤  │     Open WebUI Deployment   │   │
                    │  │     (HPA: 2-10 replicas)    │   │
                    │  └─────────────────────────────┘   │
                    │  ┌─────────────────────────────┐   │
                    │  │     Pipelines Deployment    │   │
                    │  │     (HPA: 2-5 replicas)     │   │
                    │  └─────────────────────────────┘   │
                    │  ┌─────────────────────────────┐   │
                    │  │     Keycloak StatefulSet    │   │
                    │  │     (2 replicas)            │   │
                    │  └─────────────────────────────┘   │
                    └─────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    │                               │
                    ▼                               ▼
            RDS PostgreSQL                   EFS CSI Driver
              (Multi-AZ)                    (Persistent Volumes)
```

**Pros:**
- Native horizontal pod autoscaling
- Better resource utilization
- Easier deployment updates
- Built-in service discovery

**Cons:**
- EKS control plane cost (~$75/month)
- Kubernetes expertise required
- More complex networking
- Higher initial setup effort

### Serverless Components

Some components could be replaced with serverless alternatives:

| Current | Serverless Alternative |
|---------|----------------------|
| Bedrock Gateway (EC2) | API Gateway + Lambda |
| Langfuse | Managed observability (Datadog, etc.) |
| Keycloak | Amazon Cognito |

**Trade-offs:**
- Lower operational overhead
- Pay-per-use pricing
- Vendor lock-in
- Less customization flexibility

---

## Recommendations

### For POC/Demo (Current)
✅ Keep single-instance architecture
- Simple and cost-effective
- Adequate for <50 concurrent users
- Easy to understand and debug

### For Small Team (<100 users)
🔄 Phase 1 + Phase 2
- Multi-AZ RDS for database HA
- Bedrock Gateway scaling for API throughput
- Langfuse scaling for observability

### For Production (100+ users)
🚀 Full implementation (Phases 1-4)
- All components scaled horizontally
- Consider EKS migration for easier management
- Implement comprehensive monitoring

### For Enterprise (1000+ users)
🏢 Consider:
- Multi-region deployment
- ClickHouse Cloud for analytics
- Dedicated Keycloak cluster
- API rate limiting and quotas
- Cost allocation by team/project

---

## Next Steps

1. **Assess Requirements:**
   - Expected concurrent users
   - Peak traffic patterns
   - Availability requirements (99.9%? 99.99%?)
   - Budget constraints

2. **Start with Phase 1:**
   - Low risk, high value
   - Builds foundation for further scaling
   - Validates scaling approach

3. **Monitor and Iterate:**
   - Collect metrics before scaling
   - Scale based on actual bottlenecks
   - Avoid premature optimization

---

*Document Version: 1.0*
*Last Updated: 2025-12-03*
*Author: AI Portal Team*
