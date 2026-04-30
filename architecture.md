# Architecture

This document describes the key patterns and conventions used in this GitOps Kubernetes cluster.

## Platform Stack

| Layer | Technology | Purpose |
|---|---|---|
| OS | Talos Linux | Immutable, API-managed Kubernetes OS |
| CNI | Cilium | Networking, load balancer IP allocation (eBPF) |
| GitOps | Flux CD (via flux-operator) | Reconciles git state to cluster state |
| Ingress | Envoy Gateway + Gateway API | HTTP routing, TLS termination |
| Storage | Longhorn | Distributed replicated block storage (3 replicas) |
| Secrets | External Secrets + 1Password, SOPS + Age | Secret injection from vault + encrypted git secrets |
| Metrics | VictoriaMetrics + Grafana | Time-series collection and dashboards |
| Logs | VictoriaLogs + Vector | Log aggregation and forwarding |
| Certificates | cert-manager + Let's Encrypt | Automated wildcard TLS |
| DNS | k8s-gateway (internal), cloudflare-dns (external) | Service discovery and public DNS |

## Cluster Topology

Three Talos control-plane nodes (10.69.0.10-12) behind a VIP at 10.69.0.25. Pod CIDR is 10.42.0.0/16, service CIDR is 10.43.0.0/16. Cilium handles load balancer IP assignment via the `lbipam.cilium.io/ips` annotation on services.

## GitOps Reconciliation Model

```
Git push
  |
  v
flux-system GitRepository (polls or webhook)
  |
  v
cluster-apps Kustomization (kubernetes/flux/cluster/ks.yaml)
  |  - patches ALL child Kustomizations with SOPS decryption
  |  - patches ALL child HelmReleases with install/upgrade/rollback defaults
  |
  v
Namespace kustomization.yaml (e.g. kubernetes/apps/default/kustomization.yaml)
  |  - lists each app's ks.yaml as a resource
  |  - may include ../../components/sops for cluster-secrets
  |
  v
Per-app Flux Kustomization (ks.yaml)
  |  - targets the app/ subdirectory
  |  - may declare dependsOn for ordering
  |  - may use postBuild.substituteFrom for variable injection
  |
  v
HelmRelease + supporting resources (app/ directory)
```

### Root Kustomization Patches

The root `cluster-apps` Kustomization (`kubernetes/flux/cluster/ks.yaml`) automatically injects these defaults into every child:

**For all child Kustomizations:**
- SOPS decryption enabled
- `deletionPolicy: WaitForTermination`

**For all HelmReleases (via nested patch):**
- `install.crds: CreateReplace`
- `rollback.cleanupOnFail: true`, `rollback.recreate: true`
- `upgrade.cleanupOnFail: true`, `upgrade.crds: CreateReplace`
- `upgrade.remediation.retries: 2`, `upgrade.remediation.remediateLastFailure: true`

This means individual HelmReleases do not need to repeat these fields.

## Application Structure

### Directory Layout

```
kubernetes/apps/<namespace>/<app-name>/
├── ks.yaml                          # Flux Kustomization
└── app/
    ├── kustomization.yaml           # Lists all resources
    ├── helmrelease.yaml             # Helm values and chart reference
    ├── ocirepository.yaml           # OCI chart source (app-template apps)
    │   OR helmrepository.yaml       # Traditional Helm repo source
    ├── externalsecret.yaml          # 1Password secret pull (if needed)
    └── httproute.yaml               # Gateway API route (if needed)
```

### Namespace Registration

Each namespace directory contains:
- `namespace.yaml` — the Namespace resource
- `kustomization.yaml` — lists `namespace.yaml` and all `<app>/ks.yaml` entries (alphabetically sorted)

Namespaces that need `${SECRET_DOMAIN}` or other cluster-level variables include the SOPS component:
```yaml
components:
  - ../../components/sops
```
This pulls in `cluster-secrets.sops.yaml` which provides variables for Flux `postBuild` substitution.

**Current namespaces using the SOPS component:** default, cert-manager, flux-system, kube-system, network

#### Folder ↔ namespace name

Most folders under `kubernetes/apps/` match their namespace name. Two do not — the operator chart names the namespace, and we keep the folder named for what's deployed there:

| Folder | Namespace |
|---|---|
| `database/` | `cnpg-system` (CloudNativePG operator) |
| `storage/` | `longhorn-system` |
| (everything else) | matches folder name |

#### `prune: disabled` annotation

Foundational platform namespaces carry `kustomize.toolkit.fluxcd.io/prune: disabled` on their `Namespace` resource:

- `cert-manager`
- `default`
- `flux-system`
- `kube-system`
- `network`

This tells Flux not to delete the namespace (and everything inside it) if the manifest is ever removed or renamed. Application-only namespaces (`monitoring`, `cnpg-system`, `longhorn-system`, `arc-runners`, `arc-systems`, `external-secrets`) do not carry the annotation and can be cleanly torn down by removing their kustomization entry.

### The ks.yaml Pattern

Every app has a Flux Kustomization at `<namespace>/<app>/ks.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <app-name>
  namespace: flux-system          # Always flux-system
spec:
  interval: 1h
  path: ./kubernetes/apps/<namespace>/<app-name>/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: <namespace>
  wait: false
```

**Optional fields:**

- `postBuild.substituteFrom` — enables `${SECRET_DOMAIN}` and other variables from `cluster-secrets`
- `dependsOn` — orders deployment (e.g., app depends on `onepassword-secret-store`, `external-secrets-operator`, or another app)

### Dependency Ordering

Apps declare dependencies via `dependsOn` in their `ks.yaml`. Common dependency chains:

```
external-secrets-operator
  -> onepassword-connect
    -> onepassword-secret-store
      -> apps needing 1Password secrets (argus, zone-editor, consul, jetkvm, etc.)

victoria-metrics-operator
  -> vmsingle
    -> grafana
  -> victoria-logs
    -> vector-syslog
    -> grafana

open-meteo -> weather-scraper

flux-operator -> flux-instance

cloudflare-dns -> cloudflare-dns-internal
```

## Helm Chart Patterns

### Two Chart Source Styles

**1. OCIRepository (preferred for app-template and OCI-distributed charts):**
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: <app-name>
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 4.6.2
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

The HelmRelease references it with `chartRef`:
```yaml
spec:
  chartRef:
    kind: OCIRepository
    name: <app-name>
```

**2. HelmRepository (for traditional chart repos):**
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: grafana
spec:
  interval: 1h
  url: https://grafana.github.io/helm-charts
```

The HelmRelease references it with `chart.spec`:
```yaml
spec:
  chart:
    spec:
      chart: grafana
      version: 10.x          # Allows minor/patch auto-updates
      sourceRef:
        kind: HelmRepository
        name: grafana
```

### bjw-s App-Template Conventions

Most custom applications use the [bjw-s app-template](https://github.com/bjw-s-labs/helm-charts) chart. Key value patterns:

```yaml
values:
  controllers:
    <app-name>:
      strategy: RollingUpdate
      containers:
        app:
          image:
            repository: ghcr.io/org/image
            tag: "1.0"
          env:
            HTTP_PORT: &port 80       # YAML anchor for port reuse
          probes:
            liveness: &probes         # Define once, reuse for readiness
              enabled: true
              custom: true
              spec:
                httpGet:
                  path: /healthz
                  port: *port
                initialDelaySeconds: 0
                periodSeconds: 10
                timeoutSeconds: 1
                failureThreshold: 3
            readiness: *probes        # Reuse liveness spec
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          resources:
            requests:
              cpu: 10m
            limits:
              memory: 64Mi
  defaultPodOptions:
    securityContext:
      runAsNonRoot: true
      runAsUser: 65534
      runAsGroup: 65534
  service:
    app:
      ports:
        http:
          port: *port               # Reuse anchored port
  route:                            # App-template native route support
    app:
      hostnames: ["{{ .Release.Name }}.${SECRET_DOMAIN}"]
      parentRefs:
        - name: envoy-internal      # or envoy-external
          namespace: network
          sectionName: https
      rules:
        - backendRefs:
            - identifier: app
              port: *port
```

**YAML anchor conventions:**
- `&port` / `*port` — define the service port once, reference everywhere
- `&probes` / `*probes` — define liveness probe spec, reuse for readiness

### Non-App-Template Charts

Charts like Grafana, Longhorn, and Consul use their own native values. Common patterns:
- `ingress.enabled: false` — always disabled, routing handled by separate HTTPRoute resources
- `serviceMonitor.enabled: true` — metrics exported where available
- `persistence.storageClass: longhorn` — all persistent storage uses Longhorn
- Resource requests/limits always specified

## Networking

### Gateway Architecture

Envoy Gateway manages two `Gateway` resources in the `network` namespace:

| Gateway | IP | Purpose | HTTPS listeners |
|---|---|---|---|
| `envoy-external` | 10.69.0.28 | Public access (via Cloudflare tunnel) | From: All namespaces |
| `envoy-internal` | 10.69.0.27 | Local network only | From: All namespaces |

Both share:
- A single `GatewayClass` named `envoy`
- A wildcard TLS certificate from cert-manager (Let's Encrypt)
- HTTP-to-HTTPS redirect via an `HTTPRoute` in the network namespace
- Brotli + Gzip compression (BackendTrafficPolicy)
- HTTP/2 and HTTP/3 support (ClientTrafficPolicy)
- TLS minimum version 1.2

### HTTPRoute Pattern

Apps that need web access create an HTTPRoute, either:

**Via app-template's built-in `route` key** (preferred for app-template apps):
```yaml
route:
  app:
    hostnames: ["{{ .Release.Name }}.${SECRET_DOMAIN}"]
    parentRefs:
      - name: envoy-external
        namespace: network
        sectionName: https
    rules:
      - backendRefs:
          - identifier: app
            port: *port
```

**Via a standalone HTTPRoute resource** (for non-app-template charts):
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
spec:
  hostnames: ["grafana.${SECRET_DOMAIN}"]
  parentRefs:
    - name: envoy-external
      namespace: network
      sectionName: https
  rules:
    - backendRefs:
        - name: grafana
          port: 80
```

#### Hostname convention

Always use the substituted form `"<app>.${SECRET_DOMAIN}"`, never a hardcoded hostname like `"grafana.k8s.alexieff.io"`. The substituted form is portable (the cluster could be renamed without editing every route) and keeps the domain in one place (`cluster-secrets.sops.yaml`).

For substitution to work, the app's `ks.yaml` must include:
```yaml
postBuild:
  substituteFrom:
    - name: cluster-secrets
      kind: Secret
```
The same applies anywhere `${SECRET_DOMAIN}` appears in HelmRelease values (e.g., `GF_SERVER_ROOT_URL` in Grafana) — Flux performs the substitution before the manifest is sent to the API server, so the running pod sees the resolved value.

### DNS Flow

- **Internal**: k8s-gateway watches HTTPRoute/Service resources and serves DNS for `${SECRET_DOMAIN}` on 10.69.0.26
- **External**: cloudflare-dns creates CNAME records pointing to `external.${SECRET_DOMAIN}`, which resolves to the Cloudflare tunnel endpoint

## Secrets Management

### 1Password (runtime secrets)

Used for application credentials (API keys, passwords, tokens).

```
1Password vault "k8s_vault"
  -> onepassword-connect (HTTP bridge, runs in external-secrets namespace)
    -> ClusterSecretStore "onepassword"
      -> ExternalSecret per app
        -> Kubernetes Secret
```

ExternalSecret pattern:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app>-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: <app>-secret
    creationPolicy: Owner
  data:
    - secretKey: <k8s-key>
      remoteRef:
        key: <1password-item>
        property: <1password-field>
```

### SOPS + Age (infrastructure secrets)

Used for cluster-level configuration variables committed to git.

- `.sops.yaml` at repo root defines encryption rules
- `kubernetes/components/sops/cluster-secrets.sops.yaml` — encrypted Secret providing `${SECRET_DOMAIN}` and other variables
- Talos secrets: `talos/talsecret.sops.yaml` (fully encrypted)
- Kubernetes/bootstrap secrets: only `data` and `stringData` fields encrypted

Namespaces that need these variables include the SOPS component and apps use `postBuild.substituteFrom` in their `ks.yaml`.

### Reloader

The [Stakater Reloader](https://github.com/stakater/Reloader) watches for Secret/ConfigMap changes and triggers pod restarts. Apps that depend on external secrets annotate their pods:
```yaml
annotations:
  reloader.stakater.com/auto: "true"
```

## Storage

All persistent volumes use `storageClass: longhorn` with 3 replicas (default). Longhorn provides:
- Distributed block storage across all nodes
- Automatic replica rebalancing
- Data locality optimization (best-effort)

## Observability

### Metrics Pipeline

```
ServiceMonitor / PodMonitor
  -> VictoriaMetrics operator (scrape config)
    -> VMSingle (single-node time-series DB at vmsingle-vmsingle:8429)
      -> Grafana (dashboards)
```

Apps expose metrics via `serviceMonitor` in their HelmRelease values. Grafana auto-discovers dashboards via sidecar (label: `grafana_dashboard: "1"`).

### Logs Pipeline

```
Node syslogs
  -> Vector (syslog collector on UDP 1514)
    -> VictoriaLogs (victoria-logs-single-server:9428)
      -> Grafana (via victoriametrics-logs-datasource plugin)
```

### Resource Recommendations (VPA + Goldilocks)

A Vertical Pod Autoscaler (Fairwinds chart, `kube-system/vertical-pod-autoscaler`) runs in **recommender-only** mode. The updater and admission-controller are deliberately disabled, so VPA only writes recommendations into the status of `VerticalPodAutoscaler` objects — it never restarts pods.

[Goldilocks](https://goldilocks.docs.fairwinds.com/) (`monitoring/goldilocks`) sits on top of VPA. Its controller watches all namespaces labeled

```yaml
metadata:
  labels:
    goldilocks.fairwinds.com/enabled: "true"
```

and auto-creates a `VerticalPodAutoscaler` (in `Off` mode) for every Deployment / StatefulSet inside. Recommendations populate after the recommender has 24–48 hours of metrics-server history per workload.

**All cluster namespaces are currently opted in** (label applied at the `Namespace` resource), so every workload gets a recommendation without per-app YAML edits.

#### Reading recommendations

- **Dashboard:** `https://goldilocks.${SECRET_DOMAIN}` (envoy-internal)
- **CLI:**
  ```bash
  kubectl get vpa -A
  kubectl describe vpa <name> -n <ns>          # full recommendation block
  ```

#### Flipping a workload to Auto

VPA in `Auto` mode will evict pods to apply recommended requests. Two ways to enable:

- **Per-workload:** edit the VPA's `updatePolicy.updateMode: Off` → `Auto` (or `Initial`)
- **Per-namespace default:** add `goldilocks.fairwinds.com/vpa-update-mode: "auto"` to the namespace label set, and Goldilocks will create new VPAs in Auto mode

The recommender is the only VPA component running, so flipping to `Auto` will not actually do anything until the updater + admission-controller are also enabled in the VPA HelmRelease values. Doing that is a deliberate operational decision — keep the recommender-only setup until recommendations have soaked.

## Bootstrap Sequence

Initial cluster bring-up uses helmfile (`bootstrap/helmfile.d/01-apps.yaml`) with explicit dependency ordering:

```
cilium (CNI)
  -> coredns (DNS)
    -> spegel (image mirror)
      -> cert-manager (TLS)
        -> flux-operator
          -> flux-instance (starts GitOps reconciliation)
```

After flux-instance is running, Flux takes over and reconciles everything from git.

## Automation

### Renovate

Runs on weekends. Auto-merges minor/patch updates for GitHub Actions and mise tools. Opens PRs for Helm chart and container image updates with semantic labels (`renovate/container`, `renovate/helm`, `type/major`, etc.).

### CI Validation

The `flux-local` GitHub Action validates all HelmReleases and Kustomizations on PRs, posting diffs as comments. This catches templating errors and value mismatches before merge.

Run the same checks locally with `task validate` before pushing — see `docs/local-validation.md` for the full runbook (including how to render a single HelmRelease and the WSL/Docker gotchas).

### Scaffolding

`scripts/new-app.sh` interactively generates the full app directory structure, supporting app-template, PostgreSQL, Redis, MariaDB, MongoDB, custom OCI, and custom Helm chart types.
