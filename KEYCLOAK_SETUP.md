# Keycloak SSO Integration

## Overview

This infrastructure now uses **Keycloak** as a centralized Identity Provider (IdP) for Single Sign-On (SSO) authentication.

**Authentication Flow:**
```
User → Open WebUI → Keycloak → Active Directory → Keycloak → Open WebUI
```

## Architecture

- **Keycloak**: Docker container on EC2 (t3.small)
- **Database**: PostgreSQL RDS (shared with Open WebUI, separate database: `keycloak`)
- **LDAP Backend**: AWS Managed Microsoft AD
- **Access**: https://auth.forora.com
- **Protocol**: OpenID Connect (OIDC)

## What's Configured Automatically

The userdata scripts configure everything automatically:

### Keycloak (`userdata_keycloak.sh`)
1. Creates `keycloak` database in RDS
2. Starts Keycloak in dev mode
3. Creates `aiportal` realm
4. Configures LDAP federation to Active Directory:
   - Connection: `ldap://10.0.10.72` (first AD DNS server)
   - Base DN: `OU=Users,OU=corp,DC=corp,DC=aiportal,DC=local`
   - Bind DN: `Admin@corp.aiportal.local`
   - Read-only mode
5. Creates OIDC client `openwebui`:
   - Client ID: `openwebui`
   - Client Secret: `openwebui-secret-change-this`
   - Redirect URI: `https://ai.forora.com/oauth/oidc/callback`
   - Web Origins: `https://ai.forora.com`

### Open WebUI (`userdata_open_webui.sh`)
1. Waits for Keycloak to be ready (max 10 minutes)
2. Configures OIDC authentication:
   - Discovery URL: `https://auth.forora.com/realms/aiportal/.well-known/openid-configuration`
   - Disables local login form (`ENABLE_LOGIN_FORM=false`)
   - Enables OAuth signup (`ENABLE_OAUTH_SIGNUP=true`)
3. Syncs Bedrock models
4. Creates test user in AD

## URLs

- **Open WebUI**: https://ai.forora.com
- **Keycloak Admin**: https://auth.forora.com/admin
- **Keycloak Realm**: https://auth.forora.com/realms/aiportal
- **OIDC Discovery**: https://auth.forora.com/realms/aiportal/.well-known/openid-configuration

## Login Flow

1. User visits https://ai.forora.com
2. Sees "Sign in to Open WebUI" with **SSO** button
3. Clicks SSO → redirected to Keycloak
4. Enters AD credentials: `testuser` / `Welcome@2024`
5. Keycloak authenticates against AD
6. Redirects back to Open WebUI with OIDC tokens
7. User is logged in!

## Admin Access

**Keycloak Admin Console:**
- URL: https://auth.forora.com/admin
- Username: `admin`
- Password: (value of `ad_admin_password` from terraform.tfvars)

From here you can:
- Manage users
- Configure LDAP sync
- View authentication logs
- Modify OIDC client settings

## Test User

Created automatically by userdata script:
- Username: `testuser` (or `testuser@corp.aiportal.local`)
- Password: `Welcome@2024`
- Location: Active Directory OU=Users,OU=corp,DC=corp,DC=aiportal,DC=local

## Important Notes

### Passwords
**CRITICAL**: Do NOT use `!` in passwords in `terraform.tfvars` for:
- `db_password` (RDS password)
- `keycloak_admin_password`

However, the AD password (`ad_admin_password`) CAN have `!` - it's properly escaped in the LDAP configuration.

### Security Groups
The following security group rules are required:
- RDS SG: Allow port 5432 from Keycloak SG
- Keycloak SG: Allow port 8080 from ALB SG
- Keycloak SG: Allow LDAP (389) to AD (via VPC CIDR in AD SG)

### Certificate
The ACM certificate covers both subdomains:
- `ai.forora.com` (Open WebUI)
- `auth.forora.com` (Keycloak)

### ALB Routing
Host-based routing rules:
- `ai.forora.com` → Open WebUI target group (port 8080)
- `auth.forora.com` → Keycloak target group (port 8080)

## Troubleshooting

### No SSO button on login page
- Check `OPENID_PROVIDER_URL` is set (not `OAUTH_DISCOVERY_URL`)
- Verify `ENABLE_LOGIN_FORM=false` is set
- Restart Open WebUI container: `docker-compose down && docker-compose up -d`
- Clear browser cache / hard refresh

### LDAP authentication fails in Keycloak
- Check User Federation → active-directory → Test Authentication
- Verify bind credentials match AD password
- Check AD security group allows LDAP (389) from VPC

### Keycloak won't start
- Check RDS security group allows Keycloak SG
- Verify database `keycloak` exists
- Check docker logs: `docker logs keycloak`

### Models not showing
- Run `/opt/ai-portal/sync_models.sh` manually
- Check Bedrock Gateway is accessible from Open WebUI

## Deployment Timeline

1. **Terraform Apply**: ~20-30 minutes (AD takes 10-15 min)
2. **Userdata Scripts**: ~3-5 minutes
   - Keycloak: ~2 min (database + container start)
   - Open WebUI: ~2 min (waits for Keycloak + model sync)
3. **Total**: ~25-35 minutes for complete deployment

## Next Steps After Deployment

1. Visit https://ai.forora.com
2. Click SSO button
3. Login with `testuser` / `Welcome@2024`
4. Start using Claude AI models!

Optional:
- Change default OIDC client secret in Keycloak admin
- Configure LDAP sync schedule
- Add more AD users
- Customize Keycloak theme
