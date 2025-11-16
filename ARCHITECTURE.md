# AI Portal Architecture

## High-Level Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                          AWS eu-west-2                              │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │                    VPC (10.0.0.0/16)                          │ │
│  │                                                               │ │
│  │  ┌─────────────────────────────────────────────────────────┐ │ │
│  │  │            Public Subnets (Multi-AZ)                    │ │ │
│  │  │                                                         │ │ │
│  │  │  ┌──────────────────┐      ┌──────────────────┐        │ │ │
│  │  │  │   EC2 Instance   │      │   EC2 Instance   │        │ │ │
│  │  │  │   Open WebUI     │      │ Bedrock Gateway  │        │ │ │
│  │  │  │   (t3.large)     │◄────►│   (t3.large)     │        │ │ │
│  │  │  │                  │      │                  │        │ │ │
│  │  │  │  Port: 8080      │      │  Port: 8000      │        │ │ │
│  │  │  │  Docker+Compose  │      │  FastAPI+Boto3   │        │ │ │
│  │  │  └────────┬─────────┘      └────────┬─────────┘        │ │ │
│  │  │           │                         │                  │ │ │
│  │  │           │                         │                  │ │ │
│  │  └───────────┼─────────────────────────┼──────────────────┘ │ │
│  │              │                         │                    │ │
│  │              │   ┌─────────────────────┼──────────┐         │ │
│  │              │   │  Internet Gateway   │          │         │ │
│  │              │   └─────────────────────┼──────────┘         │ │
│  │              │                         │                    │ │
│  │              │                         │                    │ │
│  │              ▼                         ▼                    │ │
│  │  ┌─────────────────────────────────────────────────────┐   │ │
│  │  │            Private Subnets (Multi-AZ)               │   │ │
│  │  │                                                     │   │ │
│  │  │  ┌──────────────────┐      ┌──────────────────┐    │   │ │
│  │  │  │   RDS PostgreSQL │      │  AWS Managed AD  │    │   │ │
│  │  │  │  (db.t3.medium)  │      │   (Standard)     │    │   │ │
│  │  │  │                  │      │                  │    │   │ │
│  │  │  │  Port: 5432      │      │  Ports: 389,     │    │   │ │
│  │  │  │  Database: aiport│      │  636, 88, 53     │    │   │ │
│  │  │  │  Single-AZ       │      │  Multi-AZ (2 DCs)│    │   │ │
│  │  │  └──────────────────┘      └──────────────────┘    │   │ │
│  │  │                                                     │   │ │
│  │  │           ┌──────────────────┐                     │   │ │
│  │  │           │   NAT Gateway    │                     │   │ │
│  │  │           └──────────────────┘                     │   │ │
│  │  └─────────────────────────────────────────────────────┘   │ │
│  │                                                             │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    AWS Bedrock (eu-west-2)                  │ │
│  │                                                             │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │   Foundation Models                                  │  │ │
│  │  │   • Claude 3.5 Sonnet                                │  │ │
│  │  │   • Claude 3 Sonnet                                  │  │ │
│  │  │   • Claude 3 Haiku                                   │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │                          ▲                                  │ │
│  │                          │                                  │ │
│  │                          │ (IAM Role)                       │ │
│  │                          │                                  │ │
│  └──────────────────────────┼───────────────────────────────────┘ │
│                             │                                     │
└─────────────────────────────┼─────────────────────────────────────┘
                              │
                     ┌────────┴────────┐
                     │   End Users     │
                     │  (Web Browser)  │
                     └─────────────────┘
```

## Component Details

### Frontend Layer

#### Open WebUI EC2 Instance
- **Instance Type**: t3.large (2 vCPU, 8 GB RAM)
- **Purpose**: Hosts the Open WebUI interface for users
- **Technology**: Docker + Docker Compose
- **Port**: 8080 (HTTP)
- **Features**:
  - Web-based chat interface
  - LDAP/OAuth authentication support
  - PostgreSQL backend for data persistence
  - Ollama API-compatible interface

#### Bedrock Access Gateway EC2 Instance
- **Instance Type**: t3.large (2 vCPU, 8 GB RAM)
- **Purpose**: Proxy/Gateway for AWS Bedrock API
- **Technology**: FastAPI + Boto3 + Uvicorn
- **Port**: 8000 (HTTP, internal only)
- **Features**:
  - Ollama-compatible API endpoints
  - Streaming support for real-time responses
  - Multiple Claude model support
  - IAM-based authentication to Bedrock

### Data Layer

#### RDS PostgreSQL Database
- **Instance Class**: db.t3.medium (2 vCPU, 4 GB RAM)
- **Engine**: PostgreSQL 15.4
- **Storage**: 20 GB gp3 (SSD)
- **Deployment**: Single-AZ (can be upgraded to Multi-AZ)
- **Features**:
  - Automated backups (7-day retention)
  - Encryption at rest
  - Private subnet deployment
  - Stores user data, conversations, and configurations

#### AWS Managed Microsoft AD
- **Edition**: Standard
- **Deployment**: Multi-AZ (2 Domain Controllers)
- **Purpose**: Enterprise authentication and authorization
- **Features**:
  - LDAP/LDAPS support
  - Kerberos authentication
  - DNS services
  - Automatic patching and backups

### Network Layer

#### VPC Configuration
- **CIDR**: 10.0.0.0/16
- **Public Subnets**: 10.0.0.0/24, 10.0.1.0/24
- **Private Subnets**: 10.0.10.0/24, 10.0.11.0/24
- **Multi-AZ**: Resources across 2 availability zones

#### Network Components
- **Internet Gateway**: Public internet access for EC2 instances
- **NAT Gateway**: Outbound internet for private resources
- **Route Tables**: Separate routing for public and private subnets

### Security Layer

#### Security Groups

1. **Open WebUI Security Group**
   - Inbound: 80, 443, 8080, 22 from allowed IPs
   - Outbound: All

2. **Bedrock Gateway Security Group**
   - Inbound: 80, 443, 8000 from VPC, 22 from allowed IPs
   - Outbound: All

3. **RDS Security Group**
   - Inbound: 5432 from EC2 instances only
   - Outbound: All

4. **Active Directory Security Group**
   - Inbound: 389, 636, 88, 53 from VPC
   - Outbound: All

#### IAM Roles
- **Bedrock Access Role**: Allows EC2 instances to invoke Bedrock models
- **Permissions**: InvokeModel, InvokeModelWithResponseStream

## Data Flow

### User Request Flow

1. **User** accesses Open WebUI via HTTP (port 8080)
2. **Open WebUI** authenticates user (optionally via AD)
3. **Open WebUI** sends chat request to Bedrock Gateway
4. **Bedrock Gateway** calls AWS Bedrock API using IAM role
5. **AWS Bedrock** processes request with Claude model
6. **Bedrock Gateway** streams response back to Open WebUI
7. **Open WebUI** displays response to user
8. **Open WebUI** stores conversation in PostgreSQL database

### Authentication Flow (LDAP/AD)

1. **User** enters credentials in Open WebUI
2. **Open WebUI** connects to AWS Managed AD via LDAP (port 389/636)
3. **AWS Managed AD** validates credentials
4. **Open WebUI** creates session and grants access

## Scalability Considerations

### Current Setup (Demo/Development)
- **Concurrent Users**: 10-50
- **Requests/Second**: ~10
- **Monthly Cost**: ~£500-600

### Production Scaling Options

1. **Horizontal Scaling**
   - Add Application Load Balancer
   - Deploy multiple Open WebUI instances (Auto Scaling Group)
   - Use ElastiCache for session management

2. **Vertical Scaling**
   - Upgrade to m5.xlarge or c5.xlarge instances
   - Increase RDS to db.m5.large or db.r5.large
   - Add Read Replicas for RDS

3. **High Availability**
   - Multi-AZ RDS deployment
   - Cross-AZ load balancing
   - CloudFront CDN for static assets

## Security Best Practices

1. **Network Security**
   - Restrict `allowed_cidr_blocks` to known IPs
   - Use VPN or Direct Connect for corporate access
   - Enable VPC Flow Logs for network monitoring

2. **Application Security**
   - Enable HTTPS with ACM certificates (add ALB)
   - Implement rate limiting at gateway
   - Enable AWS WAF for protection against attacks

3. **Data Security**
   - All EBS volumes encrypted
   - RDS encryption at rest
   - Enable CloudTrail for audit logging
   - Use AWS Secrets Manager for credentials

4. **Access Control**
   - MFA for AWS Console access
   - Least privilege IAM policies
   - Rotate database credentials regularly
   - Use AD groups for RBAC in Open WebUI

## Monitoring & Observability

### Recommended CloudWatch Metrics

1. **EC2 Instances**
   - CPU Utilization
   - Memory Utilization (requires CloudWatch agent)
   - Disk I/O

2. **RDS**
   - CPU Utilization
   - Free Storage Space
   - Read/Write IOPS
   - Database Connections

3. **Application**
   - API response times
   - Error rates
   - Request counts

### Logging Strategy

1. **Application Logs**: CloudWatch Logs
2. **Access Logs**: S3 (via ALB when added)
3. **Audit Logs**: CloudTrail
4. **VPC Traffic**: VPC Flow Logs

## Cost Optimization

### Quick Wins
1. Use Reserved Instances for predictable workloads (save ~40%)
2. Stop instances during non-business hours
3. Right-size instances based on actual usage
4. Use Spot Instances for non-critical workloads

### Long-term Optimization
1. Implement auto-scaling to match demand
2. Use S3 for file storage instead of EBS
3. Optimize Bedrock usage (cache common responses)
4. Review and cleanup unused resources monthly

## Disaster Recovery

### Backup Strategy
- **RDS**: Automated daily backups (7-day retention)
- **EC2**: Create AMIs weekly
- **AD**: AWS manages backups automatically
- **Application Config**: Store in Git

### Recovery Procedures
1. **RDS Failure**: Restore from automated backup
2. **EC2 Failure**: Launch from latest AMI
3. **AZ Failure**: Resources automatically fail over to other AZ
4. **Region Failure**: Requires cross-region replication (not included)

## Future Enhancements

1. **Add Application Load Balancer** for HTTPS and HA
2. **Implement ElastiCache** for session management
3. **Add CloudFront** for global content delivery
4. **Integrate Amazon Cognito** for additional auth options
5. **Add Amazon SES** for email notifications
6. **Implement AWS Lambda** for serverless functions
7. **Add Amazon S3** for file uploads and storage
8. **Integrate Amazon CloudWatch Dashboards** for monitoring
