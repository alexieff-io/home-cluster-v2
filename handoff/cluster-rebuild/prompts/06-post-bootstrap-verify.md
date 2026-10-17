# Fresh Session Prompt — Verify the Rebuilt Cluster

You are verifying a newly rebuilt Talos/Kubernetes GitOps cluster. You have no prior chat context. Verification must exercise behavior, not only report reconciliation.

## Inputs

- Extracted handoff package path.
- Target repository and deployed commit.
- Completed `handoff-status/05-bootstrap.yaml`.
- Authorized live access to Talos, Kubernetes, Flux, DNS, and application routes.

## Required reading

Read `inventories/applications.yaml`, all `inventories/live-snapshot/` files, `mappings/source-to-target.yaml`, `runbooks/06-verify.md`, and the bootstrap artifact.

## Task

1. Verify `talosctl health`, all four Kubernetes nodes, Cilium, Flux Git source revision, all Kustomizations, and all HelmReleases.
2. Verify External Secrets/1Password metadata readiness without reading Secret values.
3. Verify Longhorn classes and new PVC binding while recording `persistentDataRestored: false`.
4. Verify certificates, internal/external Gateways `.27`/`.28`, DNS `.26`, HTTPRoutes, Cloudflare DNS/tunnel intent, redirects, and TLS.
5. Compare all 50 mapped app IDs to target Git paths, live Flux objects, workloads, routes/services, dependencies, secret readiness, and declared state policy. No silent omission.
6. Perform one meaningful smoke action for each exposed application; use controller status/recent error logs for background applications.
7. Keep Open-Meteo suspended until the owner acknowledges its traffic; after enablement measure node traffic and verify sync logs. Verify Weather Scraper only after Open-Meteo.
8. Explicitly verify persistent applications are new/empty rather than restored.
9. Record all failures/deviations and exact evidence in `handoff-status/06-verification.yaml` plus a readable report.

## Boundaries and stop conditions

- Never print Secret values, kubeconfig data, or private keys.
- Do not call the rebuild complete because Flux alone is Ready.
- Do not invent Frigate/Omni desired state from old runtime metadata.
- Do not suppress failures, weaken health checks, or silently remove apps.
- Root-cause any failed gate before proposing a change; report unresolved failures as incomplete.

## Deliverable

Return target commit/Flux revision, cluster/Cilium/Flux health, exact 50-app parity, behavioral smoke evidence, networking/certificate/storage/secret-provider status, all deviations, `handoff-status/06-verification.yaml`, and `persistentDataRestored: false`. Declare completion only if every acceptance criterion passes.
