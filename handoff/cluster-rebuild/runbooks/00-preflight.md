# 00 — Preflight

## Goal

Prove the handoff, hardware facts, target repository, secret providers, and offline-generated configuration are ready before any cluster mutation.

## Required inputs

- Extracted package with passing internal and archive checksums.
- Access to the current source repository and cluster for comparison only.
- URL of a new empty target Git repository.
- Authorized access to the existing 1Password vault, Cloudflare account, domain, and tunnel setup.

## Checks

1. Verify package integrity from `START-HERE.md`.
2. Confirm `manifest.yaml` pins template revision `bb09348610aa5bee9505230b99c21c08db15bf6d`.
3. Confirm the source/mapping set is exact:

   ```bash
   yq '.metadata.count' inventories/applications.yaml
   yq '.metadata.applicationCount' mappings/source-to-target.yaml
   yq -r '.applications[].id' inventories/applications.yaml | sort > /tmp/source-apps
   yq -r '.applications[].id' mappings/source-to-target.yaml | sort > /tmp/target-apps
   diff -u /tmp/source-apps /tmp/target-apps
   ```

   Expected: both counts are `50`; `diff` has no output.

4. Verify the pinned template revision exists:

   ```bash
   git ls-remote https://github.com/onedr0p/cluster-template.git bb09348610aa5bee9505230b99c21c08db15bf6d
   ```

   Expected: the revision is returned. Stop if it is not reachable.

5. Compare node identity with `inventories/source-cluster.yaml`. Before wiping, use the currently authorized Talos client:

   ```bash
   talosctl get links -n 10.69.0.10,10.69.0.11,10.69.0.12,10.69.0.13
   talosctl get disks -n 10.69.0.10,10.69.0.11,10.69.0.12,10.69.0.13
   ```

   Confirm each MAC address and `/dev/mmcblk0`. Stop on a mismatch; do not guess a disk.

6. Reserve the required addresses and prove no unrelated device owns them: nodes `.10`–`.13`, API `.25`, DNS `.26`, internal Gateway `.27`, external Gateway `.28` on `10.69.0.0/24`.
7. Confirm the new target repository is empty or intentionally disposable and that the agent can push to it.
8. For a private target repository, prepare a newly generated deploy key and register only its public half. Do not reuse the private key found on the source workstation.
9. Confirm these external prerequisites without printing values:
   - existing domain `k8s.alexieff.io`;
   - Cloudflare token with required DNS/tunnel permissions;
   - Cloudflare tunnel credential source;
   - 1Password vault items/fields listed in `inventories/secrets-and-prerequisites.yaml`;
   - ability to create and safely store a new Age key pair.
10. Read all `fresh-empty-state` entries:

    ```bash
    yq -r '.applications[] | select(.statePolicy == "fresh-empty-state") | .id' inventories/applications.yaml
    ```

    Confirm the owner accepts empty databases/volumes. This package contains no data recovery path.

## Stop conditions

Stop before target generation if a checksum, inventory set, hardware fact, reserved address, Git permission, domain, secret provider, or state-loss acceptance is missing.

## Completion artifact

Create `handoff-status/00-preflight.yaml` in the target repository with boolean results for every check, package archive checksum, target repository URL, template revision, and no secret values. Later sessions must refuse to proceed unless every result is `true`.
