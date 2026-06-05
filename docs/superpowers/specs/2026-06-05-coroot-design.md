# Coroot (Community Edition) Deployment — Design

**Date:** 2026-06-05
**Status:** Approved

## Goal

Deploy [Coroot](https://docs.coroot.com/) Community Edition to the cluster as a
GitOps-managed application, following the repo's Flux + Helm conventions
(`architecture.md`, `docs/deploying-applications.md`).

Coroot is an eBPF-based observability platform (metrics, logs, traces, profiles,
cost monitoring). It is deployed via a Helm-installed **operator** plus a
**`Coroot` custom resource**; the operator reconciles the CR into the Coroot
server and its bundled data stores and agents.

## Decisions (confirmed with user)

| Decision | Choice |
|---|---|
| Edition | **Community Edition** (free, no license key) |
| Data stores | **Bundled** — operator-managed ClickHouse + Prometheus |
| Ingress | **Internal only** — `envoy-internal`, `coroot.${SECRET_DOMAIN}` |

## Architecture

Operator + custom-resource pattern, mirroring `monitoring/victoria-metrics-operator`
→ `VMSingle`. Two Flux apps under a new `coroot/` folder:

1. **`coroot-operator`** — HelmRelease for the `coroot-operator` chart. Installs the
   `coroot.com` CRDs and the operator controller. `ks.yaml` sets `wait: true` so the
   CRDs are established before the CR is applied.
2. **`coroot`** — a plain `Coroot` CR (Community Edition) + a standalone HTTPRoute.
   `ks.yaml` declares `dependsOn: coroot-operator`. The operator reconciles the CR
   into:
   - Coroot server (web UI / API, HTTP port **8080**, SQLite config DB)
   - **ClickHouse** (traces, logs, profiles)
   - **Prometheus** (metrics)
   - **node-agent** — privileged DaemonSet (eBPF) on all nodes
   - **cluster-agent** — Kubernetes cluster monitoring

Flux's root `cluster-apps` Kustomization (`path: ./kubernetes/apps`, recursive
autodetect, no top-level `kustomization.yaml`) discovers the new folder
automatically. Only the folder's own `kustomization.yaml` must list the namespace
and the two app `ks.yaml` files.

## File layout

```
kubernetes/apps/coroot/
├── kustomization.yaml              # namespace.yaml + both ks.yaml entries
├── namespace.yaml                  # ns "coroot" + goldilocks label
├── coroot-operator/
│   ├── ks.yaml                     # wait: true
│   └── app/
│       ├── kustomization.yaml
│       ├── helmrepository.yaml     # https://coroot.github.io/helm-charts
│       └── helmrelease.yaml        # chart: coroot-operator, version: 1.x
└── coroot/
    ├── ks.yaml                     # dependsOn coroot-operator; substituteFrom cluster-secrets
    └── app/
        ├── kustomization.yaml
        ├── coroot.yaml             # Coroot CR (communityEdition)
        └── httproute.yaml          # coroot.${SECRET_DOMAIN} → envoy-internal:https → coroot:8080
```

## Detailed conventions

### Namespace
- Name `coroot` (matches folder name — no folder↔namespace remap needed).
- Label `goldilocks.fairwinds.com/enabled: "true"` for VPA recommendations.
- **No** PSA label required: Talos deletes the default PodSecurity admission config
  (`talos/patches/controller/cluster.yaml`: `admissionControl: { $$patch: delete }`),
  so the privileged node-agent runs without a `pod-security.kubernetes.io/enforce`
  label — same as `monitoring/node-exporter` (`hostPID`/`hostNetwork`).
- Application-only namespace → **no** `kustomize.toolkit.fluxcd.io/prune: disabled`
  annotation (cleanly removable).

### Chart / image versioning
- Operator chart `coroot-operator` pinned to floating minor `1.x` (matches the
  grafana `10.x` / vm-operator `0.x` convention) so Renovate manages updates.
- `communityEdition.image.name` pinned to a **specific** `ghcr.io/coroot/coroot`
  tag (never `latest`, per CLAUDE.md). The exact tag is verified to exist with
  `docker manifest inspect` before commit.

### Storage (bundled stores, all on Longhorn)
| Component | Size | Notes |
|---|---|---|
| Coroot config | 10Gi | SQLite, single replica |
| Prometheus | 10Gi | retention `2d` (Coroot default) |
| ClickHouse | 10Gi | 1 shard / 1 replica; long-term traces/logs/profiles |

`storageClassName: longhorn` set on every component in the CR.

### Ingress
- Standalone `HTTPRoute` (the `Coroot` CR is not app-template, so no native
  `route` key).
- Hostname `coroot.${SECRET_DOMAIN}` (substituted form, never hardcoded).
- `parentRefs`: `envoy-internal` / `network` / `sectionName: https`.
- Backend: operator-created `coroot` Service, port `8080` — name/port confirmed
  against the chart before finalizing.
- Requires `postBuild.substituteFrom: cluster-secrets` in the `coroot` app `ks.yaml`.

### Secrets
None. CE needs no license key; single-replica SQLite config DB needs no external
Postgres. No ExternalSecret.

## Risks / to verify during implementation
1. **flux-local + kubeconform** (`task validate`) may lack the `Coroot` CRD schema
   and warn on the CR. The repo already applies schema-less CRs (VMSingle, Gateway
   API), so tolerance is expected; if it hard-fails, wire in the CRD schema or a
   documented skip and report back.
2. **Service name/port** (`coroot:8080`) confirmed against the operator chart
   before finalizing the HTTPRoute backend.
3. **Resource footprint** — ClickHouse + Prometheus add IO load on Longhorn; sizes
   start conservative (10Gi) and can grow. (See also the standing note on SD-card
   etcd IOPS — Coroot's stores live on Longhorn, not etcd, so no direct etcd impact.)

## Out of scope
- Enterprise features (SSO, RBAC, multi-cluster, long retention).
- Reusing the existing VictoriaMetrics stack for Coroot metrics.
- External (public) exposure.
- Grafana dashboards / VM ServiceMonitor for Coroot's own components.
