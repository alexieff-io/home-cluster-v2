# Cluster Rebuild Handoff

This package lets an independent agent build a fresh repository from `onedr0p/cluster-template`, preserve this cluster's non-secret topology and GitOps application configuration, and perform a controlled offline rebuild.

## Contract

- **Target template:** `https://github.com/onedr0p/cluster-template`
- **Pinned revision:** `bb09348610aa5bee9505230b99c21c08db15bf6d`
- **Application inventory:** 50 source applications, each mapped exactly once.
- **Topology:** reuse `node1`–`node4`, `10.69.0.10`–`10.69.0.13`, API VIP `10.69.0.25`, and gateway addresses `10.69.0.26`–`10.69.0.28`.
- **State policy:** configuration only. All new PVCs, databases, indexes, and application data start empty.
- **Cutover:** offline. The old and new clusters cannot coexist with the same addresses.

## Integrity check

From the directory containing the archive:

```bash
sha256sum -c cluster-rebuild.tar.gz.sha256
tar -xzf cluster-rebuild.tar.gz
cd cluster-rebuild
sha256sum -c checksums.sha256
```

Stop if either checksum command fails.

## Security boundary

The package intentionally excludes kubeconfigs, Talos secrets/configs, Age private keys, deploy private keys, Cloudflare credential JSON, token files, etcd snapshots, volume contents, databases, and decrypted SOPS values. Two SOPS-encrypted Kubernetes Secret manifests are retained only as ciphertext so the next agent can identify what must be recreated and re-encrypted.

Never ask an agent to infer a missing credential. Supply secrets only through an authorized out-of-band channel and commit them only where the generated template encrypts them with SOPS.

## Reading and session order

1. `manifest.yaml`
2. `inventories/source-cluster.yaml`
3. `inventories/applications.yaml`
4. `inventories/dependencies.yaml`
5. `mappings/template-overlap.yaml`
6. `mappings/source-to-target.yaml`
7. `runbooks/00-preflight.md` through `runbooks/06-verify.md`
8. Use `prompts/01-generate-target.md` through `prompts/06-post-bootstrap-verify.md` in separate sessions.

Each prompt is self-contained but requires the named completion artifact from its predecessor. Do not skip sessions or substitute chat history for a completion artifact.

## Non-destructive boundary

Sessions 1–4 prepare and validate the target repository without changing the current cluster. Session 5 is the first destructive stage. It must show the exact node list and the statement below, then receive explicit authorization in that same session:

> Wiping node1–node4 destroys the current cluster. This package does not contain persistent application data and cannot restore it.

The existence of this package is not authorization.

## Known risks

- Four control-plane nodes form an even etcd member count. This is preserved by request, not recommended as an availability improvement.
- Open-Meteo's sync container currently creates sustained S3 download traffic. Preserve its config but disclose the impact before enabling it.
- Live-only `frigate`, `omni`, `cilium-secrets`, and `lynq-system` metadata has no matching source application directory and is not a migration unit.
- Current Helm status metadata records retry/rollback anomalies for Argus Panoptes, Paperless-ngx, and Grafana. A new deployment must be verified from behavior, not assumed healthy from the old status.
