# Fresh Session Prompt — Generate the Target Repository

You are preparing a replacement Talos/Kubernetes GitOps cluster from a self-contained handoff package. You have no prior chat context. Do not mutate any live cluster in this session.

## Inputs

- Extracted package root: ask for its filesystem path once if it is not supplied.
- New empty target Git repository URL: ask once if not recorded externally.
- Source of authorized domain/Cloudflare/1Password prerequisites; never ask for secret values in chat if a safer provider is available.
- Pinned template: `https://github.com/onedr0p/cluster-template` at `bb09348610aa5bee9505230b99c21c08db15bf6d`.

## Required reading

Read package files `START-HERE.md`, `manifest.yaml`, `inventories/source-cluster.yaml`, `inventories/applications.yaml`, `inventories/secrets-and-prerequisites.yaml`, `runbooks/00-preflight.md`, and `runbooks/01-generate-target.md` before changing files.

## Task

1. Verify archive/internal checksums and exact 50-app source/mapping parity.
2. Complete every non-destructive preflight check reachable from the package and current authorized environment.
3. Create a fresh target repository from the pinned template revision, not moving `main`.
4. Run the pinned template's `mise`, `just init`, and `just configure` workflow.
5. Merge `payload/cluster.toml.example`, replacing only explicit sentinels through authorized inputs.
6. Verify node/MAC/disk/IP/CIDR/Gateway values and SOPS encryption.
7. Push a validated generated baseline to the target remote.
8. Create and commit `handoff-status/00-preflight.yaml` and `handoff-status/01-target-generated.yaml` with no secret values.

## Boundaries

- Do not run Talos reset/apply/bootstrap or Kubernetes apply commands.
- Do not copy source Age/deploy private keys, kubeconfigs, Talos secrets, tunnel JSON, tokens, snapshots, or application data.
- Do not continue if hardware facts, target repository, required external providers, or empty-state acceptance is missing.
- Do not claim completion unless a fresh clone of the target commit renders successfully.

## Deliverable

Return the target repository URL/path and commit, template pin, exact validation commands/results, both completion artifact paths, unresolved blockers, and `clusterMutationPerformed: false`.
