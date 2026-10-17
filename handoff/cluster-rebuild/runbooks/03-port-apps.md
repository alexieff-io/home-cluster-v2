# 03 — Port Applications

## Gate

Require passing `handoff-status/02-platform-ported.yaml`. This stage remains offline and non-destructive.

## Authoritative set

The application set is the exact intersection proven by:

```bash
yq -r '.applications[].id' inventories/applications.yaml | sort > /tmp/source-apps
yq -r '.applications[].id' mappings/source-to-target.yaml | sort > /tmp/mapped-apps
diff -u /tmp/source-apps /tmp/mapped-apps
```

Expected: 50 IDs and no diff. Template-owned/platform IDs already completed in session 2 remain part of parity but must not be copied again.

## Port in waves

Process `mappings/source-to-target.yaml` in `deploymentWave` order. For wave 5–7 records:

1. Copy the record's `sourcePath` into its `targetPath`.
2. Adapt it to generated target conventions instead of copying namespace/root kustomizations blindly.
3. Register the app exactly once.
4. Update the GitRepository `sourceRef` and `spec.path` to the target repository.
5. Preserve `dependsOn`, including explicit namespaces.
6. Preserve chart source/version and image configuration unless compatibility requires a documented change.
7. Preserve services, routes, hostnames, internal/external Gateway intent, probes, resources, and security contexts.
8. Preserve ExternalSecret names/references but leave enablement gated on session 4.
9. For every `fresh-empty-state` record, create only the desired PVC/database declarations. Do not import PV names, volume handles, snapshots, database dumps, or live PVC metadata.

Wave meanings:

- 5: stateless applications.
- 6: applications that provision empty state.
- 7: downstream applications, notably Weather Scraper after Open-Meteo.

## Required application-specific disclosures

- **Open-Meteo:** current sync settings download large model datasets from S3 and have produced 5–15 MiB/s node traffic. Keep it disabled or suspended until the cutover owner acknowledges the impact.
- **Paperless-ngx, LibreChat, Argus Panoptes, Coroot, Grafana, VictoriaMetrics/Logs, Consul, and other persistent services:** they start empty. A Ready pod does not imply old data exists.
- **Live-only Frigate and Omni routes/services:** do not invent source apps. Record them as intentionally omitted runtime drift unless the user supplies desired-state manifests.

## Validate each wave

After every wave:

- run `just configure` where template inputs remain;
- run the target repository's generated Flux/render validation;
- prove all target paths and namespace resources exist;
- parse every YAML document;
- compare mapped IDs against target app registrations;
- inspect sourceRef, dependsOn, valuesFrom, substituteFrom, ExternalSecret, and Gateway parent references;
- ensure no decrypted secret or private key is present.

Do not enable a later wave by weakening an earlier dependency.

## Stop conditions

Stop on missing app IDs, duplicate registrations, unresolved dependencies, invalid chart APIs, missing secret prerequisites, unsafe Secret content, or any claim that empty storage restores old state.

## Completion artifact

Write and commit `handoff-status/03-apps-ported.yaml` containing all 50 IDs with owner, target path, wave, validation result, state policy, compatibility changes, and `clusterMutationPerformed: false`.
