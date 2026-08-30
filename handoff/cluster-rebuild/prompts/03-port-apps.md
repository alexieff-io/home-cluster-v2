# Fresh Session Prompt — Port All Applications

You are porting application desired state into an already generated and platform-populated target repository. You have no prior chat context. Do not mutate a live cluster.

## Inputs

- Extracted handoff package path.
- Target repository working tree.
- Required predecessor artifact: `handoff-status/02-platform-ported.yaml` with all checks passing.

## Required reading

Read `inventories/applications.yaml`, `inventories/dependencies.yaml`, `inventories/secrets-and-prerequisites.yaml`, `mappings/source-to-target.yaml`, `runbooks/03-port-apps.md`, and every payload app you change.

## Task

1. Prove the source inventory and source-to-target map contain the same 50 unique IDs.
2. Confirm template-owned and wave 1–4 records are already accounted for exactly once.
3. Port wave 5, then wave 6, then wave 7 apps using each record's source/target paths, namespace, dependencies, state policy, and adaptations.
4. Preserve behavior, chart/image versions, routes, services, probes, resources, and security contexts unless a pinned-template compatibility issue requires a documented change.
5. Preserve ExternalSecret references without inventing values.
6. For every `fresh-empty-state` record, retain desired storage declarations but import no PV/PVC identifiers or data.
7. Keep Open-Meteo suspended or explicitly gated and record its known sustained S3 traffic impact.
8. Validate after each wave: target render, all YAML, paths/registrations, dependency/source/substitution/secret/Gateway references, and secret leak scan.
9. Create and commit `handoff-status/03-apps-ported.yaml` listing all 50 IDs and results.

## Boundaries and stop conditions

- Do not invent desired state for live-only Frigate/Omni metadata.
- Do not silently omit an app or register one twice.
- Do not update versions or redesign behavior merely because a newer option exists.
- Do not describe an empty PVC/database as restored.
- Stop on missing/duplicate IDs, unresolved references, invalid APIs/charts, unsafe Secret content, or target validation failure.

## Deliverable

Return commits, exact 50-ID parity evidence, per-wave validation evidence, compatibility deviations, all fresh-empty-state acknowledgements, `handoff-status/03-apps-ported.yaml`, blockers, and `clusterMutationPerformed: false`.
