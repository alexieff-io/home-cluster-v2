# Home Cluster v2

GitOps-managed Kubernetes homelab running on Talos Linux, orchestrated by Flux CD.

## Project Structure

```
.
├── bootstrap/helmfile.d/     # Initial cluster bootstrap (cilium, coredns, flux, cert-manager)
├── kubernetes/
│   ├── apps/                 # All application deployments, organized by namespace
│   │   ├── <namespace>/
│   │   │   ├── kustomization.yaml   # Lists all apps in this namespace
│   │   │   ├── namespace.yaml       # Namespace resource
│   │   │   └── <app>/
│   │   │       ├── ks.yaml          # Flux Kustomization (points to app/)
│   │   │       └── app/
│   │   │           ├── kustomization.yaml
│   │   │           ├── helmrelease.yaml
│   │   │           ├── ocirepository.yaml or helmrepository.yaml
│   │   │           ├── externalsecret.yaml    (optional)
│   │   │           └── httproute.yaml         (optional)
│   │   └── ...
│   ├── components/sops/      # Shared SOPS component (cluster-secrets)
│   └── flux/cluster/ks.yaml  # Root Kustomization — applies all apps with default patches
├── talos/                    # Talos OS node configuration (talconfig.yaml)
├── scripts/                  # Utility scripts (new-app.sh, bootstrap-apps.sh, etc.)
├── .taskfiles/               # Task runner definitions (bootstrap/, talos/)
└── .github/workflows/        # CI: flux-local validation, PR labeling
```

### Namespaces

arc-runners, arc-systems, cert-manager, database, default, external-secrets, flux-system, kube-system, monitoring, network, storage

## Key Conventions

### App Deployment Pattern

Every app follows the same structure: `kubernetes/apps/<namespace>/<app-name>/ks.yaml` + `app/` subdirectory.

- **ks.yaml**: Flux Kustomization in `flux-system` namespace, references `app/` path, uses `postBuild.substituteFrom` for cluster-secrets variable substitution
- **app/helmrelease.yaml**: Flux HelmRelease using either `chartRef` (OCIRepository) or `chart.spec` (HelmRepository)
- **app/kustomization.yaml**: Lists all resources in the app directory

Register new apps by adding `./<app-name>/ks.yaml` to the namespace's `kustomization.yaml` (keep alphabetically sorted).

### Helm Charts

- **bjw-s/app-template** (via OCI): Primary chart for custom apps — `oci://ghcr.io/bjw-s-labs/helm/app-template`
- Chart sources use either `OCIRepository` (preferred for app-template) or `HelmRepository`
- YAML anchors are used for port reuse: `port: &port 80` then `*port`
- Probe pattern: define `liveness: &probes` then `readiness: *probes`

### Networking (Gateway API)

Uses Envoy Gateway with Gateway API (not Ingress):

- **envoy-internal**: Local network access (10.69.0.27)
- **envoy-external**: Public access via Cloudflare tunnel (10.69.0.28)
- Routes use `HTTPRoute` with `parentRefs` pointing to gateway in `network` namespace
- Domain templating: `"{{ .Release.Name }}.${SECRET_DOMAIN}"`
- DNS: k8s-gateway for internal resolution, cloudflare-dns for public records

### Secrets

Two mechanisms:

1. **SOPS + Age**: Encrypted secrets committed to git (`.sops.yaml` files). Used for `cluster-secrets` providing variable substitution (`${SECRET_DOMAIN}`, etc.)
2. **PRIMARY METHOD** **External Secrets + 1Password**: `ExternalSecret` resources pull from 1Password via `onepassword-connect`. Use `ClusterSecretStore` named `onepassword`

### Security Defaults

HelmReleases should include:
```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }
defaultPodOptions:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
```

### Flux Reconciliation

The root Kustomization (`kubernetes/flux/cluster/ks.yaml`) patches all child Kustomizations with:
- SOPS decryption enabled
- HelmRelease defaults: CRD CreateReplace, rollback with cleanup, upgrade remediation with 2 retries

## Common Commands

```bash
# Force Flux to sync from Git
task reconcile

# Bootstrap Talos cluster from scratch
task bootstrap:talos

# Bootstrap apps into cluster
task bootstrap:apps

# Generate Talos config after editing talconfig.yaml
task talos:generate-config

# Apply Talos config to a node
task talos:apply-node IP=10.69.0.10

# Upgrade Talos on a node
task talos:upgrade-node IP=10.69.0.10

# Upgrade Kubernetes version
task talos:upgrade-k8s

# Scaffold a new application deployment (interactive)
./scripts/new-app.sh

# Re-sync all external secrets
./scripts/resync-external-secrets.sh
```

## Tools (managed by mise)

Key tools: kubectl, flux, helm, helmfile, talosctl, talhelper, sops, age, kustomize, kubeconform, task

Install all with: `mise install`

## CI/CD

- **flux-local.yaml**: Validates HelmReleases and Kustomizations on PRs, posts diffs as PR comments
- **Renovate**: Runs on weekends, auto-merges minor/patch GitHub Actions and mise tool updates
- **Flux webhook**: Auto-reconciles on git push

## Important Notes

- Always verify container image tags exist before specifying them (`docker manifest inspect`)
- The `default` namespace kustomization includes a `components` reference to `../../components/sops` for cluster-secrets
- Environment variables `KUBECONFIG`, `SOPS_AGE_KEY_FILE`, and `TALOSCONFIG` are set via `.mise.toml` and `Taskfile.yaml`
- Cluster nodes: 3 control planes at 10.69.0.10-12, VIP at 10.69.0.25
- Pod CIDR: 10.42.0.0/16, Service CIDR: 10.43.0.0/16
- Cilium provides CNI and LoadBalancer IP allocation (`lbipam.cilium.io/ips` annotation)
