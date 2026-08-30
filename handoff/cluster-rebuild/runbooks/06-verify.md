# 06 — Verify the Rebuilt Cluster

## Gate

Require a completed `05-bootstrap.yaml` and live access to the rebuilt cluster. Verification is evidence collection, not a reason to bypass failed dependencies.

## Cluster foundation

Run and save sanitized results:

```bash
talosctl health
kubectl get nodes -o wide
cilium status --wait
flux get sources git -A
flux get ks -A
flux get hr -A
```

Expected:

- all four nodes Ready at `.10`–`.13`;
- Kubernetes API reachable at `.25`;
- Cilium healthy across four nodes;
- Flux source revision matches the pushed target commit;
- every expected Flux Kustomization and HelmRelease Ready.

Investigate any `Ready=False`, stalled, retry-exhausted, or missing object. Flux reconciliation alone is not application verification.

## Secrets, storage, and certificates

Verify metadata/status without reading Secret values:

```bash
kubectl get clustersecretstores,secretstores,externalsecrets -A
kubectl get storageclasses
kubectl get pvc -A
kubectl get certificates,certificaterequests,orders,challenges -A
```

Expected:

- 1Password ClusterSecretStore and required ExternalSecrets Ready;
- Longhorn storage classes available;
- new claims Bound at requested sizes;
- claims contain fresh/empty state by design;
- wildcard/application certificates Ready.

## Networking

```bash
kubectl get gateways,httproutes -A
kubectl get services -A
```

Confirm:

- DNS Gateway `10.69.0.26`;
- Envoy internal `10.69.0.27` and external `10.69.0.28`;
- internal and external hostnames preserve the mapping inventory;
- local DNS resolves internal routes;
- Cloudflare DNS/tunnel publishes only intended external routes;
- HTTP redirects/TLS and application backends work.

Do not recreate live-only Frigate/Omni routes unless the user supplied desired-state manifests.

## Application parity

Export live Flux Kustomization identities and compare them to `mappings/source-to-target.yaml`, accounting for the generated root Kustomizations. For each of the 50 application IDs, record:

- target path exists in Git;
- Flux object exists and is Ready;
- expected workload/controller exists;
- rollout/readiness succeeds;
- routes/services answer where declared;
- required ExternalSecrets are Ready;
- state policy is acknowledged.

No application may be silently omitted. A deliberate incompatibility must be reported with evidence and user disposition.

## Behavioral smoke checks

Exercise each exposed application through its declared route. Check one representative successful action, not merely TCP reachability. For non-HTTP/background apps, inspect controller status and recent error logs.

Special checks:

- Open-Meteo remains suspended until the owner accepts its S3 traffic; after enablement, measure node traffic and sync logs.
- Weather Scraper runs only after Open-Meteo is healthy.
- Paperless-ngx, LibreChat, Argus Panoptes, databases, Grafana, Coroot, VictoriaMetrics/Logs, Consul, and all other persistent apps clearly report new/empty state.
- ARC controller/runner resources authenticate and create the intended runner scale set without exposing tokens.

## Acceptance

The rebuild is complete only when cluster foundation, secret providers, storage, certificates, networking, exact app parity, and behavioral checks all pass. Record deviations rather than describing partial success as completion.

## Completion artifact

Write `handoff-status/06-verification.yaml` and a human-readable report containing every check, command timestamp, target commit/revision, failed items, intentional omissions, and the statement `persistentDataRestored: false`. Include no Secret values, kubeconfigs, private keys, or low-entropy secret hashes.
