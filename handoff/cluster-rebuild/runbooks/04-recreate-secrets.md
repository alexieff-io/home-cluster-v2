# 04 — Recreate Secrets and External Prerequisites

## Gate

Require passing `handoff-status/03-apps-ported.yaml`. This stage prepares encrypted Git state and external providers but does not wipe or bootstrap nodes.

## New trust chain

Use the Age key created by the pinned template's `just init`. Do not copy `age.key`, Talos secrets, deploy private keys, kubeconfig, or any other private credential from the source repository/workstation into the target repository.

Confirm the target `.sops.yaml` recipient matches the new public recipient. Store the private key only in the authorized workstation/password manager and in the target cluster bootstrap secret mechanism defined by the template.

## Recreate SOPS values

The payload contains these encrypted source manifests only as identification/reference ciphertext:

- `payload/components/sops/cluster-secrets.sops.yaml`
- `payload/apps/external-secrets/onepassword-connect/app/secret.sops.yaml`

Do not commit them unchanged: they target the old Age recipient. Through an authorized out-of-band process, recreate their required values and encrypt new target manifests for the new recipient. `SECRET_DOMAIN` is known as `k8s.alexieff.io`; 1Password Connect credential material must come from the authorized provider, never from package content.

Verify encryption without decryption output:

```bash
sops filestatus <target-sops-file>
```

Expected: encrypted status for every target SOPS file. Never use commands that print decrypted values into logs or completion artifacts.

## Reconnect External Secrets

Use `inventories/secrets-and-prerequisites.yaml` as the exact reference list.

1. Deploy definitions in dependency order: External Secrets operator, 1Password Connect credentials, 1Password Connect, then ClusterSecretStore.
2. Confirm every referenced 1Password item and property exists. Do not rename a missing property to make reconciliation appear successful.
3. Confirm ExternalSecret target Secret names match application `valuesFrom`, `envFrom`, and `secretKeyRef` references.
4. Confirm the Cloudflare token and tunnel credential are newly supplied through generated encrypted resources or External Secrets.
5. For Git/Flux private repository access, use the newly generated deploy key and registered public key.

Before the cluster exists, validate structure offline. Provider connectivity is verified after bootstrap before applications are unsuspended.

## Leak checks

Review the target Git index, not only the working tree, for:

- PEM/OpenSSH private-key headers;
- Age private-key markers;
- kubeconfig client keys/tokens;
- Cloudflare tunnel account/tag/secret JSON;
- plaintext values in Kubernetes `Secret.data` or `Secret.stringData`;
- unencrypted copies produced by an editor or SOPS temporary file.

Any match must be removed from history or rotated as appropriate before push. Merely adding it to `.gitignore` after commit is not sufficient.

## Stop conditions

Stop if a new Age trust chain is not proven, an ExternalSecret source item/field is missing, provider access is unavailable, plaintext entered Git history, or an application expects a Secret not represented in the inventory.

## Completion artifact

Write and commit `handoff-status/04-secrets-ready.yaml` listing each secret resource by name and provider only, SOPS encrypted-status results, ExternalSecret reference existence checks, rotations performed, and `containsSecretValues: false`. Do not include hashes of low-entropy secrets.
