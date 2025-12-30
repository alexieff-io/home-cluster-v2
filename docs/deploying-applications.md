# Deploying Applications to the Cluster

## Overview

This guide walks through deploying a new application to the Kubernetes cluster using Flux CD GitOps workflow. Applications are deployed using Helm charts (typically the bjw-s app-template) and managed via Flux HelmReleases.

## Application Architecture

```
GitRepository (flux-system)
    ↓
Flux Kustomization (ks.yaml)
    ↓
├── HelmRelease ────→ OCIRepository/HelmRepository
├── ExternalSecret ──→ 1Password
├── HTTPRoute ────────→ Envoy Gateway ──→ Internet
└── PersistentVolumeClaim (if needed)
```

## Directory Structure

Applications follow this directory structure:

```
kubernetes/apps/
├── <namespace>/
│   ├── <app-name>/
│   │   ├── ks.yaml                    # Flux Kustomization
│   │   └── app/
│   │       ├── kustomization.yaml     # Kustomize manifest
│   │       ├── helmrelease.yaml       # Helm chart deployment
│   │       ├── ocirepository.yaml     # Chart source (OCI)
│   │       └── externalsecret.yaml    # Secrets (optional)
│   ├── kustomization.yaml             # Namespace-level kustomization
│   └── namespace.yaml                 # Namespace definition
```

## Step-by-Step Deployment

### 1. Create Directory Structure

```bash
# Create the application directory
mkdir -p kubernetes/apps/<namespace>/<app-name>/app

# Example: deploying myapp to default namespace
mkdir -p kubernetes/apps/default/myapp/app
```

### 2. Create Namespace (if new)

If deploying to a new namespace, create `kubernetes/apps/<namespace>/namespace.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: myapp-ns
```

And `kubernetes/apps/<namespace>/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./namespace.yaml
  - ./myapp/ks.yaml
```

### 3. Create Flux Kustomization

Create `kubernetes/apps/<namespace>/<app-name>/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: myapp
spec:
  interval: 1h
  path: ./kubernetes/apps/<namespace>/<app-name>/app
  postBuild:
    substituteFrom:
      - name: cluster-secrets
        kind: Secret
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: <namespace>
  wait: false
```

**Key fields:**
- `path`: Points to the app directory
- `postBuild.substituteFrom`: Enables variable substitution (e.g., `${SECRET_DOMAIN}`)
- `targetNamespace`: Where the app will be deployed
- `prune: true`: Removes resources when deleted from Git

### 4. Create OCIRepository

Create `kubernetes/apps/<namespace>/<app-name>/app/ocirepository.yaml`:

For bjw-s app-template (recommended for most apps):

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: myapp
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 4.4.0  # Check for latest version
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

For other charts, use HelmRepository instead:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: myapp-repo
spec:
  interval: 1h
  url: https://charts.example.com
```

### 5. Create HelmRelease

Create `kubernetes/apps/<namespace>/<app-name>/app/helmrelease.yaml`:

**Basic example (no ingress):**

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: myapp
spec:
  chartRef:
    kind: OCIRepository
    name: myapp
  interval: 1h
  values:
    controllers:
      myapp:
        strategy: RollingUpdate
        containers:
          app:
            image:
              repository: ghcr.io/myorg/myapp
              tag: v1.0.0
            env:
              APP_PORT: &port 8080
            probes:
              liveness: &probes
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /health
                    port: *port
                  initialDelaySeconds: 0
                  periodSeconds: 10
                  timeoutSeconds: 1
                  failureThreshold: 3
              readiness: *probes
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities: { drop: ["ALL"] }
            resources:
              requests:
                cpu: 100m
                memory: 128Mi
              limits:
                memory: 512Mi
    defaultPodOptions:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
    service:
      app:
        ports:
          http:
            port: *port
```

### 6. Add Secrets (if needed)

If your app requires secrets, create an ExternalSecret. First, add the secret to 1Password (see [External Secrets Setup](./external-secrets-setup.md)).

Create `kubernetes/apps/<namespace>/<app-name>/app/externalsecret.yaml`:

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: myapp-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: myapp-secret
    creationPolicy: Owner
  data:
    - secretKey: api-key
      remoteRef:
        key: myapp-api-key    # Item title in 1Password
        property: password     # Field name
    - secretKey: database-url
      remoteRef:
        key: myapp-database
        property: password
```

Reference the secret in your HelmRelease:

```yaml
containers:
  app:
    envFrom:
      - secretRef:
          name: myapp-secret
    # Or for individual keys:
    env:
      API_KEY:
        valueFrom:
          secretKeyRef:
            name: myapp-secret
            key: api-key
```

### 7. Add Ingress (HTTPRoute)

For applications that need external access, add a `route` section to your HelmRelease values:

```yaml
spec:
  values:
    # ... other values ...
    route:
      app:
        hostnames: ["myapp.${SECRET_DOMAIN}"]
        parentRefs:
          - name: envoy-external    # or envoy-internal for internal-only
            namespace: network
            sectionName: https      # or http for non-TLS
        rules:
          - backendRefs:
              - identifier: app
                port: 8080
```

**Available Gateways:**
- `envoy-external`: Public internet access (namespace: `network`)
- `envoy-internal`: Internal cluster access only (namespace: `network`)

**TLS/SSL:**
TLS certificates are automatically provisioned by cert-manager using Let's Encrypt when you use `sectionName: https`. The certificate is requested via DNS-01 challenge using Cloudflare.

**DNS:**
DNS records are automatically created by external-dns (cloudflare-dns) when you create the HTTPRoute. No manual DNS configuration needed!

### 8. Add Persistent Storage (if needed)

For applications requiring persistent storage, add a `persistence` section:

**Using PVC (Persistent Volume Claim):**

```yaml
spec:
  values:
    persistence:
      data:
        type: persistentVolumeClaim
        storageClass: local-path  # or your storage class
        accessMode: ReadWriteOnce
        size: 10Gi
        globalMounts:
          - path: /data
```

**Using ConfigMap:**

```yaml
spec:
  values:
    configMaps:
      config:
        data:
          config.yaml: |-
            # Your config content
            key: value
    persistence:
      config-file:
        type: configMap
        identifier: config
        globalMounts:
          - path: /etc/myapp/config.yaml
            subPath: config.yaml
```

**Using EmptyDir (temporary):**

```yaml
persistence:
  cache:
    type: emptyDir
    globalMounts:
      - path: /tmp/cache
```

**Multiple Volumes:**

```yaml
persistence:
  data:
    type: persistentVolumeClaim
    size: 10Gi
    globalMounts:
      - path: /data
  logs:
    type: emptyDir
    globalMounts:
      - path: /var/log/myapp
  config:
    type: configMap
    identifier: config
    globalMounts:
      - path: /etc/myapp
```

### 9. Create Kustomization Manifest

Create `kubernetes/apps/<namespace>/<app-name>/app/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
  - ./externalsecret.yaml  # if you created one
```

### 10. Update Namespace Kustomization

Add your app to `kubernetes/apps/<namespace>/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./namespace.yaml
  - ./existing-app/ks.yaml
  - ./myapp/ks.yaml  # Add this line
```

### 11. Commit and Deploy

```bash
# Stage all files
git add kubernetes/apps/<namespace>/<app-name>/

# Commit
git commit -m "feat: add myapp deployment"

# Push to repository
git push

# Reconcile Flux (optional - Flux will auto-sync within 1 hour)
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization cluster-apps -n flux-system
```

### 12. Verify Deployment

```bash
# Check Flux Kustomization
flux get kustomizations -n flux-system

# Check HelmRelease status
kubectl get helmrelease -n <namespace> myapp

# Check pods
kubectl get pods -n <namespace>

# Check ExternalSecret (if created)
kubectl get externalsecret -n <namespace> myapp-secret

# Check HTTPRoute (if created)
kubectl get httproute -n <namespace> myapp

# Check logs
kubectl logs -n <namespace> -l app.kubernetes.io/name=myapp -f
```

## Complete Example

Here's a complete working example deploying a simple web application with ingress, secrets, and persistence:

<details>
<summary><b>kubernetes/apps/default/myapp/ks.yaml</b></summary>

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: myapp
spec:
  interval: 1h
  path: ./kubernetes/apps/default/myapp/app
  postBuild:
    substituteFrom:
      - name: cluster-secrets
        kind: Secret
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: default
  wait: false
```
</details>

<details>
<summary><b>kubernetes/apps/default/myapp/app/kustomization.yaml</b></summary>

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
  - ./externalsecret.yaml
```
</details>

<details>
<summary><b>kubernetes/apps/default/myapp/app/ocirepository.yaml</b></summary>

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: myapp
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 4.4.0
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```
</details>

<details>
<summary><b>kubernetes/apps/default/myapp/app/externalsecret.yaml</b></summary>

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: myapp-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: myapp-secret
    creationPolicy: Owner
  data:
    - secretKey: api-key
      remoteRef:
        key: myapp-api-key
        property: password
```
</details>

<details>
<summary><b>kubernetes/apps/default/myapp/app/helmrelease.yaml</b></summary>

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: myapp
spec:
  chartRef:
    kind: OCIRepository
    name: myapp
  interval: 1h
  values:
    controllers:
      myapp:
        strategy: RollingUpdate
        annotations:
          reloader.stakater.com/auto: "true"  # Auto-reload on secret changes
        containers:
          app:
            image:
              repository: ghcr.io/myorg/myapp
              tag: v1.0.0
            env:
              APP_PORT: &port 8080
              LOG_LEVEL: info
            envFrom:
              - secretRef:
                  name: myapp-secret
            probes:
              liveness: &probes
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /health
                    port: *port
                  initialDelaySeconds: 10
                  periodSeconds: 10
                  timeoutSeconds: 1
                  failureThreshold: 3
              readiness: *probes
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities: { drop: ["ALL"] }
            resources:
              requests:
                cpu: 100m
                memory: 128Mi
              limits:
                memory: 512Mi
    defaultPodOptions:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
    service:
      app:
        ports:
          http:
            port: *port
    route:
      app:
        hostnames: ["myapp.${SECRET_DOMAIN}"]
        parentRefs:
          - name: envoy-external
            namespace: network
            sectionName: https
        rules:
          - backendRefs:
              - identifier: app
                port: *port
    persistence:
      data:
        type: persistentVolumeClaim
        storageClass: local-path
        accessMode: ReadWriteOnce
        size: 10Gi
        globalMounts:
          - path: /data
      cache:
        type: emptyDir
        globalMounts:
          - path: /tmp/cache
```
</details>

## Advanced Topics

### Using Custom Helm Charts

For applications not using app-template:

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: postgresql
spec:
  chart:
    spec:
      chart: postgresql
      version: 12.x
      sourceRef:
        kind: HelmRepository
        name: bitnami
  interval: 1h
  values:
    # Chart-specific values
    auth:
      username: myuser
      existingSecret: postgresql-secret
```

### Multiple Containers

```yaml
controllers:
  myapp:
    containers:
      app:
        image:
          repository: ghcr.io/myorg/myapp
          tag: v1.0.0
        # ... app config
      sidecar:
        image:
          repository: ghcr.io/myorg/sidecar
          tag: v1.0.0
        # ... sidecar config
```

### Init Containers

```yaml
controllers:
  myapp:
    initContainers:
      init-db:
        image:
          repository: busybox
          tag: latest
        command:
          - sh
          - -c
          - "echo 'Initializing...'"
    containers:
      app:
        # ... main container
```

### Service Monitors (Prometheus)

```yaml
serviceMonitor:
  app:
    enabled: true
    endpoints:
      - port: http
        path: /metrics
        interval: 30s
```

### Ingress with Path-Based Routing

```yaml
route:
  app:
    hostnames: ["myapp.${SECRET_DOMAIN}"]
    parentRefs:
      - name: envoy-external
        namespace: network
        sectionName: https
    rules:
      - matches:
          - path:
              type: PathPrefix
              value: /api
        backendRefs:
          - identifier: api
            port: 8080
      - matches:
          - path:
              type: PathPrefix
              value: /
        backendRefs:
          - identifier: frontend
            port: 3000
```

### Resource Quotas

```yaml
resources:
  requests:
    cpu: 100m      # Minimum CPU (millicores)
    memory: 128Mi  # Minimum memory
  limits:
    cpu: 1000m     # Maximum CPU
    memory: 512Mi  # Maximum memory
```

## Troubleshooting

### HelmRelease Not Reconciling

```bash
# Check HelmRelease status
kubectl describe helmrelease -n <namespace> <name>

# Check Flux logs
kubectl logs -n flux-system deployment/helm-controller -f

# Force reconciliation
flux reconcile helmrelease -n <namespace> <name>
```

### HTTPRoute Not Working

```bash
# Check HTTPRoute status
kubectl describe httproute -n <namespace> <name>

# Check Gateway status
kubectl get gateway -n network

# Check if certificate was issued
kubectl get certificate -A

# Check Envoy logs
kubectl logs -n network -l app.kubernetes.io/name=envoy-gateway -f
```

### ExternalSecret Errors

See [External Secrets Setup - Troubleshooting](./external-secrets-setup.md#troubleshooting)

### Pod CrashLoopBackOff

```bash
# Check pod logs
kubectl logs -n <namespace> <pod-name> --previous

# Check pod events
kubectl describe pod -n <namespace> <pod-name>

# Check resource usage
kubectl top pod -n <namespace> <pod-name>
```

### PVC Issues

```bash
# Check PVC status
kubectl get pvc -n <namespace>

# Check PV
kubectl get pv

# Describe PVC for events
kubectl describe pvc -n <namespace> <pvc-name>
```

## Best Practices

### Security

- ✅ Always use `runAsNonRoot: true`
- ✅ Drop all capabilities: `capabilities: { drop: ["ALL"] }`
- ✅ Use `readOnlyRootFilesystem: true` when possible
- ✅ Use specific user/group IDs (not root: 0)
- ✅ Store secrets in 1Password, not in Git

### Resources

- ✅ Always set resource requests and limits
- ✅ Start conservative, increase based on monitoring
- ✅ Set memory limits to prevent OOM kills
- ✅ Use liveness and readiness probes

### Monitoring

- ✅ Add ServiceMonitor for Prometheus metrics
- ✅ Configure appropriate probe intervals
- ✅ Log to stdout/stderr (not files)
- ✅ Use structured logging (JSON)

### Updates

- ✅ Pin image tags (don't use `latest`)
- ✅ Use semantic versioning
- ✅ Test updates in a staging environment
- ✅ Use Renovate/Dependabot for automated updates

### Storage

- ✅ Use emptyDir for temporary/cache data
- ✅ Use PVC only when data must persist
- ✅ Set appropriate access modes (RWO, RWX, ROX)
- ✅ Include size limits

## Common Application Patterns

### Stateless Web Application
- No persistence
- HTTPRoute with external access
- Secrets from 1Password
- Horizontal scaling ready

### Stateful Database
- PVC for data persistence
- Internal-only access (envoy-internal or no HTTPRoute)
- Secrets for credentials
- Backup strategy

### Background Worker
- No service or HTTPRoute
- Potentially shares PVC with main app
- Queue credentials from secrets

### Cron Job
```yaml
controllers:
  cronjob:
    type: cronjob
    cronjob:
      schedule: "0 2 * * *"  # Daily at 2 AM
    containers:
      app:
        # ... container config
```

## Resources

- [bjw-s app-template Documentation](https://bjw-s.github.io/helm-charts/docs/app-template/)
- [Flux CD Documentation](https://fluxcd.io/flux/)
- [Envoy Gateway Documentation](https://gateway.envoyproxy.io/)
- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [cert-manager Documentation](https://cert-manager.io/)
- [External Secrets Setup](./external-secrets-setup.md)

## Quick Reference Commands

```bash
# Deploy new app
git add kubernetes/apps/<namespace>/<app>/
git commit -m "feat: add <app>"
git push
flux reconcile kustomization cluster-apps -n flux-system

# Check status
kubectl get helmrelease -A
kubectl get externalsecret -A
kubectl get httproute -A
kubectl get pods -A

# View logs
kubectl logs -n <namespace> -l app.kubernetes.io/name=<app> -f

# Force reconciliation
flux reconcile helmrelease -n <namespace> <app>

# Suspend/Resume
flux suspend helmrelease -n <namespace> <app>
flux resume helmrelease -n <namespace> <app>

# Delete app
git rm -r kubernetes/apps/<namespace>/<app>/
git commit -m "chore: remove <app>"
git push
flux reconcile kustomization cluster-apps -n flux-system
```
