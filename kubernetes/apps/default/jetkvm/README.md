# JetKVM Cloud API Deployment

This directory contains the Kubernetes manifests for deploying the JetKVM Cloud API with CloudNativePG for database management.

## Architecture

- **Database**: CloudNativePG managed PostgreSQL cluster (3 replicas)
- **Application**: JetKVM Cloud API (2 replicas)
- **Storage**: Longhorn for persistent volumes
- **Ingress**: Envoy Gateway with HTTPRoute
- **Secrets**: ExternalSecrets with 1Password integration

## Directory Structure

```
jetkvm/
├── ks.yaml                           # Flux Kustomization
└── app/
    ├── kustomization.yaml            # Kustomize configuration
    ├── postgres-cluster.yaml         # CloudNativePG Cluster resource
    ├── postgres-externalsecret.yaml  # Database credentials
    ├── app-externalsecret.yaml       # Application secrets
    ├── deployment.yaml               # API deployment with migration init container
    ├── service.yaml                  # ClusterIP service
    └── httproute.yaml                # Ingress route
```

## Prerequisites

Before deploying, you need to create the following items in 1Password:

### 1. Create `jetkvm-postgres` item in 1Password

Required fields:
- `password` - PostgreSQL password for the jetkvm user

### 2. Create `jetkvm-cloud-api` item in 1Password

Required fields:
- `google_client_id` - Google OAuth client ID
- `google_client_secret` - Google OAuth client secret
- `api_hostname` - API hostname (e.g., `https://jetkvm-api.k8s.alexieff.io`)
- `app_hostname` - Frontend app hostname (e.g., `https://jetkvm.k8s.alexieff.io`)
- `cloudflare_turn_id` - Cloudflare TURN service ID
- `cloudflare_turn_token` - Cloudflare TURN service token
- `cookie_secret` - Random secret for session cookies (generate with `openssl rand -base64 32`)
- `r2_endpoint` - Cloudflare R2 or S3-compatible endpoint
- `r2_access_key_id` - R2/S3 access key
- `r2_secret_access_key` - R2/S3 secret key
- `r2_bucket` - R2/S3 bucket name
- `r2_cdn_url` - CDN URL for R2/S3 bucket
- `cors_origins` - Comma-separated list of allowed CORS origins
- `ice_servers` - Comma-separated list of ICE servers for WebRTC (e.g., `stun:stun.l.google.com:19302`)

## Deployment Steps

### 1. Update the main kustomization

Add the JetKVM kustomization to your cluster's main kustomization file:

```bash
# Add to kubernetes/apps/default/kustomization.yaml
# or wherever your default namespace apps are defined
```

### 2. Update the HTTPRoute hostname

Edit `app/httproute.yaml` and change the hostname to match your domain:

```yaml
hostnames:
  - "jetkvm-api.your-domain.com"  # Change this
```

### 3. Configure DNS

Add a DNS record pointing to your ingress:
- **Hostname**: `jetkvm-api.k8s.alexieff.io` (or your chosen hostname)
- **Type**: A or CNAME
- **Target**: Your cluster's external IP or ingress endpoint

### 4. Deploy

Commit and push your changes:

```bash
git add kubernetes/apps/default/jetkvm/
git commit -m "Add JetKVM Cloud API deployment with CloudNativePG"
git push
```

Flux will automatically apply the changes. Monitor the deployment:

```bash
# Watch the Flux Kustomization
flux get kustomizations -w

# Check the PostgreSQL cluster status
kubectl get clusters.postgresql.cnpg.io -n default

# Check pods
kubectl get pods -n default -l app.kubernetes.io/name=jetkvm-cloud-api

# Check database pods
kubectl get pods -n default -l cnpg.io/cluster=jetkvm-postgres
```

## CloudNativePG Services

The CNPG operator automatically creates these services:

- **jetkvm-postgres-rw**: Read-Write service (primary replica)
- **jetkvm-postgres-ro**: Read-Only service (read replicas)
- **jetkvm-postgres-r**: Direct pod access service

The application uses `jetkvm-postgres-rw` for all database operations.

## Verification

### 1. Check database cluster

```bash
kubectl get cluster jetkvm-postgres -n default
kubectl describe cluster jetkvm-postgres -n default
```

### 2. Check ExternalSecrets

```bash
kubectl get externalsecrets -n default | grep jetkvm
kubectl get secrets -n default | grep jetkvm
```

### 3. Check application pods

```bash
kubectl get pods -n default -l app.kubernetes.io/name=jetkvm-cloud-api
kubectl logs -n default -l app.kubernetes.io/name=jetkvm-cloud-api --tail=100
```

### 4. Check migrations

The init container runs Prisma migrations before the app starts:

```bash
kubectl logs -n default <pod-name> -c prisma-migrate
```

### 5. Test the API

```bash
curl https://jetkvm-api.k8s.alexieff.io
```

## Maintenance

### Backup Configuration (Optional)

To enable backups, uncomment and configure the backup section in `postgres-cluster.yaml`:

1. Create an S3 bucket for backups
2. Create a secret with S3 credentials
3. Uncomment the backup configuration
4. Apply the changes

### Scaling

#### Scale the application:

```bash
kubectl scale deployment jetkvm-cloud-api -n default --replicas=3
```

Or edit `deployment.yaml` and commit.

#### Scale the database:

Edit `postgres-cluster.yaml` and change `instances: 3` to your desired number, then commit.

### Monitoring

If you have Prometheus installed, the CNPG operator exports metrics:

```bash
kubectl get podmonitor -n default
```

## Troubleshooting

### Database connection issues

```bash
# Check database service
kubectl get svc -n default | grep jetkvm-postgres

# Check database logs
kubectl logs -n default jetkvm-postgres-1

# Test connection from a debug pod
kubectl run -it --rm debug --image=postgres:16 --restart=Never -- \
  psql postgresql://jetkvm:PASSWORD@jetkvm-postgres-rw.default.svc.cluster.local:5432/jetkvm
```

### Migration failures

```bash
# Check init container logs
kubectl logs -n default <pod-name> -c prisma-migrate

# Manually run migrations
kubectl exec -it -n default <pod-name> -- npx prisma migrate deploy
```

### Secret issues

```bash
# Check ExternalSecret status
kubectl describe externalsecret jetkvm-cloud-api-env -n default

# Check if secret was created
kubectl get secret jetkvm-cloud-api-env -n default -o yaml
```

## Cleanup

To remove the deployment:

```bash
# Remove the Flux Kustomization
kubectl delete kustomization jetkvm -n flux-system

# Or delete resources directly
kubectl delete -k kubernetes/apps/default/jetkvm/app/

# Note: PVCs are not automatically deleted for safety
kubectl get pvc -n default | grep jetkvm-postgres
```
