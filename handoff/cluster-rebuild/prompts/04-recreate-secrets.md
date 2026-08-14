# Fresh Session Prompt — Recreate Secrets Safely

You are preparing the target repository's secret trust chain and external providers. You have no prior chat context. Do not mutate or wipe the current cluster.

## Inputs

- Extracted handoff package path.
- Target repository working tree.
- Required predecessor artifact: `handoff-status/03-apps-ported.yaml` with all checks passing.
- Authorized out-of-band access to the target Age key storage, 1Password vault, Cloudflare account/tunnel, and Git deploy-key settings.

## Required reading

Read `inventories/secrets-and-prerequisites.yaml`, `runbooks/04-recreate-secrets.md`, the target `.sops.yaml`, and the pinned template's generated secret/bootstrap instructions.

## Task

1. Prove the target has a newly generated Age recipient and safe private-key storage.
2. Recreate target SOPS manifests for cluster substitutions and 1Password Connect using authorized values; never commit the old payload ciphertext unchanged as final configuration.
3. Verify each target file with `sops filestatus <file>` without printing decrypted content.
4. Reconnect External Secrets in operator → 1Password Connect → ClusterSecretStore order.
5. Verify every ExternalSecret item/property, target Secret name, valuesFrom/envFrom/secretKeyRef, Cloudflare prerequisite, and Git deploy-key public registration.
6. Scan the Git index/history and working tree for private keys, kubeconfigs, Talos credentials, tunnel credential JSON, plaintext Kubernetes Secret values, decrypted files, and token assignments.
7. Remove and rotate any leaked credential before pushing; `.gitignore` alone is not remediation.
8. Commit encrypted/reference-only desired state and `handoff-status/04-secrets-ready.yaml` with `containsSecretValues: false`.

## Boundaries and stop conditions

- Never paste or print secrets into chat, logs, status artifacts, or commands captured by shell history when a secure provider is available.
- Never include `AGE-SECRET-KEY-`, deploy private keys, kubeconfig auth data, Talos secrets, or tunnel credential JSON in Git.
- Do not hash low-entropy secrets as proof.
- Stop on missing provider access/item/property, wrong Age recipient, unencrypted Secret fields, unresolved app Secret reference, or leaked credential history.
- Do not run bootstrap/apply commands.

## Deliverable

Return target commits, names/providers of recreated resources only, SOPS encrypted-status evidence, ExternalSecret reference parity, credential rotations (without values), leak-scan results, `handoff-status/04-secrets-ready.yaml`, blockers, and `clusterMutationPerformed: false`.
