# External Secrets Operator + 1Password Setup

## Overview

This cluster uses **External Secrets Operator (ESO)** integrated with **1Password** for centralized secret management. Secrets are stored in 1Password and automatically synced to Kubernetes secrets via ESO.

### Architecture

```
1Password Cloud
    ↓
1Password Connect Server (self-hosted)
    ↓
ClusterSecretStore (ESO)
    ↓
ExternalSecret Resources
    ↓
Kubernetes Secrets
```

## Components

### 1. External Secrets Operator
- **Namespace**: `external-secrets`
- **Purpose**: Kubernetes operator that syncs secrets from external sources
- **Location**: `kubernetes/apps/external-secrets/external-secrets-operator/`

### 2. 1Password Connect Server
- **Namespace**: `external-secrets`
- **Purpose**: Self-hosted bridge between ESO and 1Password cloud
- **Location**: `kubernetes/apps/external-secrets/onepassword-connect/`
- **Credentials**: Stored in SOPS-encrypted secret (base64url-encoded)

### 3. ClusterSecretStore
- **Name**: `onepassword`
- **Purpose**: Configures ESO connection to 1Password Connect Server
- **Location**: `kubernetes/apps/external-secrets/onepassword-secret-store/`
- **Vault**: `k8s_vault` (ID: `2lakyyhua5nj3l3upj6jl5y6we`)

## Adding New Secrets

### Step 1: Create Item in 1Password

1. Open 1Password and navigate to the `k8s_vault` vault
2. Create a new **Password** item:
   - **Title**: Use kebab-case (e.g., `my-app-secret`)
   - **Password field**: Enter the secret value
   - **Save** the item

### Step 2: Create ExternalSecret Resource

Create a new file `externalsecret.yaml` in your application directory:

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-app-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: my-app-secret
    creationPolicy: Owner
  data:
    - secretKey: my-key
      remoteRef:
        key: my-app-secret      # Item title in 1Password
        property: password       # Field name (use 'password' for Password-type items)
```

**Key Fields:**
- `secretKey`: The key name in the Kubernetes secret
- `remoteRef.key`: The item title in 1Password (must match exactly)
- `remoteRef.property`: The field name in 1Password
  - For **Password** items: use `password`
  - For **Custom fields**: use the field name

### Step 3: Update Kustomization

Add the ExternalSecret to your `kustomization.yaml`:

```yaml
resources:
  - ./externalsecret.yaml
  - ./helmrelease.yaml
```

### Step 4: Commit and Apply

```bash
git add .
git commit -m "feat: add my-app-secret ExternalSecret"
git push
flux reconcile kustomization cluster-apps -n flux-system
```

### Step 5: Verify

```bash
# Check ExternalSecret status
kubectl get externalsecret -n <namespace> my-app-secret

# Verify secret creation
kubectl get secret -n <namespace> my-app-secret

# Check secret value (if needed)
kubectl get secret -n <namespace> my-app-secret -o jsonpath='{.data.my-key}' | base64 -d
```

## Managing Multiple Fields

For secrets with multiple fields, add multiple `data` entries:

```yaml
spec:
  data:
    - secretKey: username
      remoteRef:
        key: my-app-credentials
        property: username
    - secretKey: password
      remoteRef:
        key: my-app-credentials
        property: password
```

## Common 1Password Item Types

| Item Type | Property Field | Example |
|-----------|---------------|---------|
| Password | `password` | API tokens, passwords |
| Login | `username`, `password` | Database credentials |
| API Credential | `credential` | Some API keys |

**Important**: Always verify the property field name matches the 1Password item type.

## Troubleshooting

### ExternalSecret Shows "SecretSyncedError"

**Error**: `key not found in 1Password Vaults`

**Solutions**:
1. Verify the item exists in 1Password `k8s_vault`
2. Check the item title matches `remoteRef.key` exactly (case-sensitive)
3. Verify the property field name is correct for the item type
4. Restart 1Password Connect Server to force resync:
   ```bash
   kubectl delete pod -n external-secrets -l app.kubernetes.io/name=onepassword-connect
   ```

### ClusterSecretStore Shows "Invalid"

**Error**: `status 401: Invalid bearer token`

**Solutions**:
1. Verify the Connect Server Access Token is valid
2. Check token expiration in 1Password
3. Update token in secret if needed:
   ```bash
   kubectl edit secret -n external-secrets onepassword-connect-secret
   ```

### Connect Server Startup Errors

**Error**: `illegal base64 data at input byte 0`

**Solution**: Credentials must be base64url-encoded (not standard base64):
```bash
echo 'CREDENTIALS_JSON' | base64 -w0 | tr '+/' '-_' | tr -d '='
```

### Secrets Not Syncing After Adding to 1Password

**Solution**: The Connect Server caches vault contents. Restart it:
```bash
kubectl delete pod -n external-secrets -l app.kubernetes.io/name=onepassword-connect
sleep 10
kubectl get pods -n external-secrets
```

## Monitoring

### Check All ExternalSecrets

```bash
kubectl get externalsecret -A
```

Expected output:
```
NAMESPACE      NAME                    STATUS         READY
cert-manager   cert-manager-secret     SecretSynced   True
flux-system    github-webhook-token    SecretSynced   True
network        cloudflare-dns-secret   SecretSynced   True
```

### Check ClusterSecretStore Status

```bash
kubectl get clustersecretstore onepassword
```

Expected: `STATUS: Valid, READY: True`

### View 1Password Connect Logs

```bash
# API logs
kubectl logs -n external-secrets deployment/onepassword-connect -c connect-api --tail=50

# Sync logs
kubectl logs -n external-secrets deployment/onepassword-connect -c connect-sync --tail=50
```

### View ESO Operator Logs

```bash
kubectl logs -n external-secrets deployment/external-secrets-operator --tail=50
```

## Refreshing Secrets

ExternalSecrets refresh automatically based on `refreshInterval` (default: 1h).

**Manual refresh**:
```bash
kubectl annotate externalsecret -n <namespace> <name> force-sync=$(date +%s) --overwrite
```

## Updating Secret Values

1. Update the value in 1Password
2. Wait for automatic refresh (up to 1h), or trigger manual refresh
3. Restart pods if needed (some apps don't reload secrets dynamically):
   ```bash
   kubectl rollout restart deployment/<name> -n <namespace>
   ```

## Security Considerations

### Secrets in Git
- ❌ **Never commit plain secrets** to Git
- ✅ Only commit ExternalSecret manifests (which reference 1Password items)
- ✅ 1Password Connect credentials are SOPS-encrypted

### Access Control
- 1Password vault permissions control who can view/modify secrets
- Kubernetes RBAC controls which pods can access secrets
- ClusterSecretStore requires proper authentication token

### Token Management
- **Connect Server Access Token**: Stored in SOPS-encrypted secret
- Rotate tokens periodically in 1Password
- Update token secret in cluster after rotation

## Migration from SOPS

The cluster previously used SOPS + Age encryption. The following secrets have been migrated:

| Secret | Original Location | New Location |
|--------|------------------|--------------|
| cloudflare-dns-secret | `secret.sops.yaml` | 1Password: `cloudflare-api-token` |
| cert-manager-secret | `secret.sops.yaml` | 1Password: `cloudflare-api-token` |
| github-webhook-token-secret | `secret.sops.yaml` | 1Password: `github-webhook-token` |
| cloudflare-tunnel-secret | `secret.sops.yaml` | 1Password: `cloudflare-tunnel-token` |

**SOPS Still Used For**:
- Talos secrets (`talos/talsecret.sops.yaml`)
- Bootstrap Age keys (`bootstrap/sops-age.sops.yaml`)
- 1Password Connect credentials (`kubernetes/apps/external-secrets/onepassword-connect/app/secret.sops.yaml`)

## Key Technical Decisions

### Base64URL Encoding
1Password Connect Server requires credentials in base64url format (RFC 4648):
- Uses `-` and `_` instead of `+` and `/`
- No padding (`=`)
- Command: `base64 -w0 | tr '+/' '-_' | tr -d '='`

### Token Types
- **Connect Server Access Token** (JWT): Used by ESO to authenticate with Connect Server
- **Service Account Token** (starts with `ops_`): NOT compatible with Connect Server

### Property Field Names
Different 1Password item types use different field names:
- Password items: `property: password`
- Login items: `property: username` or `property: password`
- Custom fields: Use the exact field name

### Helm Chart Source
Using HelmRepository instead of OCIRepository for 1Password Connect:
```yaml
sourceRef:
  kind: HelmRepository  # More reliable than OCI registry
  name: onepassword
```

## Maintenance

### Regular Tasks
- [ ] Review and rotate 1Password tokens quarterly
- [ ] Monitor ExternalSecret sync status
- [ ] Update External Secrets Operator (check releases)
- [ ] Update 1Password Connect chart version

### Backup Strategy
- Secrets are stored in 1Password (primary source of truth)
- 1Password has built-in backup/versioning
- Kubernetes secrets are ephemeral and automatically recreated by ESO

## Resources

- [External Secrets Operator Docs](https://external-secrets.io/)
- [1Password Connect](https://developer.1password.com/docs/connect/)
- [ESO 1Password Provider](https://external-secrets.io/latest/provider/1password/)

## Support

For issues:
1. Check ExternalSecret status and events
2. Review 1Password Connect logs
3. Verify item exists in 1Password vault
4. Restart Connect Server if needed
5. Check this documentation's troubleshooting section
