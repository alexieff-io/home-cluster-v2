# Home Cluster v2

GitOps-managed Kubernetes homelab running on Talos Linux, orchestrated by Flux CD.

> **Source of truth for conventions and patterns:** `architecture.md` and `docs/*.md`.
> Read those first before reverse-engineering anything from example app files. This file
> is intentionally a high-level pointer plus operational quick-reference, not a full spec.

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
├── .github/workflows/        # CI: flux-local validation, PR labeling
├── architecture.md           # Conventions, patterns, and architectural decisions
└── docs/                     # Per-topic guides (deploying-applications, local-validation, etc.)
```

### Namespaces

`arc-runners`, `arc-systems`, `cert-manager`, `cnpg-system` (folder: `database/`),
`default`, `external-secrets`, `flux-system`, `kube-system`, `longhorn-system`
(folder: `storage/`), `monitoring`, `network`.

Note that two folders don't match their namespace name — see the table in `architecture.md` → "Namespace Registration".

## Conventions — see architecture.md

The following live in `architecture.md` to avoid drift; do not duplicate them here:

- **App Deployment Pattern** (ks.yaml + app/ layout, namespace registration, dependency ordering) — `architecture.md` → "Application Structure"
- **Helm Chart Patterns** (OCIRepository vs HelmRepository, version pinning, app-template values, YAML anchors, security context defaults) — `architecture.md` → "Helm Chart Patterns"
- **Networking** (Envoy gateways, HTTPRoute pattern, hostname convention, DNS flow) — `architecture.md` → "Networking"
- **Secrets** (1Password via External Secrets, SOPS+Age for cluster-secrets, Reloader) — `architecture.md` → "Secrets Management"
- **Flux reconciliation model** (root Kustomization, default patches) — `architecture.md` → "GitOps Reconciliation Model"
- **Resource recommendations** (VPA + Goldilocks, namespace label, dashboard) — `architecture.md` → "Observability"

## Common Commands

```bash
# Validate manifests locally before pushing (matches CI)
task validate

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

- **flux-local.yaml**: Validates HelmReleases and Kustomizations on PRs, posts diffs as PR comments. Run the same checks locally with `task validate` — see `docs/local-validation.md`.
- **Renovate**: Runs on weekends, auto-merges minor/patch GitHub Actions and mise tool updates
- **Flux webhook**: Auto-reconciles on git push

## Operational Quick-Reference

- Always verify container image tags exist before specifying them (`docker manifest inspect`)
- Cluster nodes: 4 control planes (`node1`–`node4`) at 10.69.0.10-13, VIP at 10.69.0.25
- Pod CIDR: 10.42.0.0/16, Service CIDR: 10.43.0.0/16
- Cilium provides CNI and LoadBalancer IP allocation (`lbipam.cilium.io/ips` annotation)
- Environment variables `KUBECONFIG`, `SOPS_AGE_KEY_FILE`, and `TALOSCONFIG` are set via `.mise.toml` and `Taskfile.yaml`
