# 01 — Generate the Fresh Target Repository

## Gate

Require `handoff-status/00-preflight.yaml` with every check `true`. This stage is non-destructive to the current cluster.

## Create the repository at the pinned revision

Use a fresh working directory. Clone the template, pin it, and reinitialize only that disposable clone for the new remote:

```bash
git clone https://github.com/onedr0p/cluster-template.git new-cluster
cd new-cluster
git checkout bb09348610aa5bee9505230b99c21c08db15bf6d
rm -rf .git
git init -b main
git remote add origin <TARGET_REPOSITORY_URL>
```

`<TARGET_REPOSITORY_URL>` is the URL recorded by preflight. Stop if the current directory contains unrelated files or if the remote is not the intended fresh repository.

## Initialize the pinned template

```bash
mise trust
mise install
just init
```

The initialization creates the target repository's own Age/deploy material. Store private material outside Git exactly as the pinned template documents.

Merge `payload/cluster.toml.example` into the generated `cluster.toml`:

- preserve every topology value already provided;
- replace the repository sentinel with the target repository URL;
- supply the Cloudflare token only through the generated secret/encryption workflow;
- retain domain `k8s.alexieff.io` and `cloudflare-tunnel` ingress unless the user explicitly changes the design;
- retain all four node records, MAC addresses, and `/dev/mmcblk0` disks.

Reject any unresolved `REPLACE_WITH_` sentinel:

```bash
rg 'REPLACE_WITH_' cluster.toml
```

Expected: no output.

## Render and validate

```bash
just configure
```

Review generated files for:

- `node1`–`node4` and exact static addresses;
- API VIP `10.69.0.25`;
- pod/service CIDRs `10.42.0.0/16` and `10.43.0.0/16`;
- Gateway addresses `10.69.0.26`, `.27`, `.28`;
- ARM64-compatible Talos schematic and `/dev/mmcblk0`;
- encrypted SOPS files under `bootstrap/`, `kubernetes/`, and `talos/`;
- no private key or plaintext token tracked by Git.

Do not run `just bootstrap talos` or `just bootstrap apps` in this stage.

## Establish the baseline

Commit and push only after the generated baseline validates:

```bash
git add -A
git commit -m "chore: generate pinned cluster template"
git push -u origin main
```

For a private repository, register the generated public deploy key before expecting Flux access. Never commit the private half.

## Stop conditions

Stop on template drift, unresolved sentinels, render failure, unencrypted secret files, incorrect hardware/network output, or inability to push/clone the target repository.

## Completion artifact

Write and commit `handoff-status/01-target-generated.yaml` with template revision, target commit, rendered node/IP summary, SOPS encryption checks, push/clone checks, and `clusterMutationPerformed: false`.
