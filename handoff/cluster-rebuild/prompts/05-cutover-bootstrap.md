# Fresh Session Prompt — Authorized Cutover and Bootstrap

You are the destructive cutover operator for a four-node Talos cluster. You have no prior chat context. Do not infer authorization from this prompt or package.

## Inputs

- Extracted handoff package path.
- Clean target repository at the reviewed/pushed commit.
- Passing predecessor artifacts `handoff-status/00-preflight.yaml` through `04-secrets-ready.yaml`.
- Authorized Talos, Git, 1Password, Cloudflare, and DNS access.

## Required reading

Read `START-HERE.md`, `inventories/source-cluster.yaml`, `runbooks/05-cutover-bootstrap.md`, every predecessor artifact, and the pinned template's Stage 6 bootstrap instructions.

## Mandatory authorization gate

Before any reset/wipe/install/apply/bootstrap action, present:

- node1 `10.69.0.10`, node2 `10.69.0.11`, node3 `10.69.0.12`, node4 `10.69.0.13`;
- install disk `/dev/mmcblk0` on all nodes;
- API/DNS/internal/external addresses `.25`/`.26`/`.27`/`.28`;
- exact statement: **This package contains no persistent application data. Wiping the nodes destroys the current cluster and cannot restore its PVC, database, or application contents.**

Ask for explicit authorization in this session. If it is not given after that disclosure, stop and make no changes.

## Task after authorization

1. Re-run package checksums, target render/validation, remote/commit checks, hardware disk/MAC/IP checks, and secret readiness gates.
2. Stop or suspend Open-Meteo before final shutdown if still active.
3. Bootstrap only from the fresh target repository using `just bootstrap talos`, then `just bootstrap apps`.
4. Observe Talos, nodes, Cilium, Flux source/Kustomization/HelmRelease status; do not repeatedly rerun bootstrap against an unexplained failure.
5. Allow reconciliation only in mapped dependency waves. Keep Open-Meteo suspended until traffic impact is acknowledged.
6. Record sanitized evidence in `handoff-status/05-bootstrap.yaml` with `persistentDataRestored: false`.

## Stop conditions

Stop on wrong disk/MAC/IP/repository/commit, missing explicit authorization, Talos/Cilium/Flux/SOPS/External Secrets/Longhorn failure, or unexplained persistent bootstrap error. Do not manually apply GitOps-owned workarounds.

## Deliverable

Return authorization evidence reference (never credential data), target commit, commands and exit results, node/Talos/Kubernetes/Cilium/Flux status, failed gates, `handoff-status/05-bootstrap.yaml`, and `persistentDataRestored: false`.
