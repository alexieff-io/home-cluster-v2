# 05 — Authorized Cutover and Bootstrap

## Gates

Require committed, passing artifacts `00-preflight.yaml` through `04-secrets-ready.yaml`, a clean/pushed target repository, and a fresh clone/render check. Re-run package checksums and target validation immediately before cutover.

This is the first destructive stage.

## Mandatory authorization

Present this exact scope before running a reset/wipe/install command:

- Nodes: `node1` `10.69.0.10`, `node2` `10.69.0.11`, `node3` `10.69.0.12`, `node4` `10.69.0.13`.
- Install disk on every node: `/dev/mmcblk0`.
- Reused virtual addresses: API `.25`, DNS `.26`, internal Gateway `.27`, external Gateway `.28`.
- Data-loss statement: **This package contains no persistent application data. Wiping the nodes destroys the current cluster and cannot restore its PVC, database, or application contents.**

Receive explicit authorization in this session after presenting that statement. The package, earlier design approval, or general intention to rebuild is not authorization. Without it, stop.

## Final isolation checks

- Confirm the target working directory and remote.
- Confirm Talos configs were generated from the pinned target repository.
- Confirm each IP/MAC/disk mapping again.
- Confirm no unrelated host owns the reused IPs.
- Confirm the current cluster is expected to go offline.
- Suspend or stop high-traffic Open-Meteo before the final wipe if the current cluster is still serving it.

## Bootstrap using the pinned template

Follow the pinned template's generated `just` commands from the target repository:

```bash
just bootstrap talos
just bootstrap apps
```

Do not substitute old `bootstrap/` files from the payload. The generated template owns Talos, Cilium, CoreDNS, Spegel, Flux, and initial sync.

Observe rather than repeatedly rerunning bootstrap commands:

```bash
kubectl get nodes --watch
kubectl get pods --all-namespaces --watch
flux get sources git -A
flux get ks -A
flux get hr -A
```

Expected transient API/CNI errors during early bootstrap are documented by the pinned template. A persistent failure requires root-cause investigation; do not stack repeated resets or manual resource applies on top of an unknown failure.

## Reconciliation order

1. Template bootstrap resources and Flux.
2. Secret provider chain.
3. Storage/database/core operators.
4. Observability/supporting platform resources.
5. Stateless applications.
6. Empty-state applications.
7. Explicit downstream applications.

Keep Open-Meteo suspended until network impact is acknowledged. Stateful applications remain expected-empty.

## Stop conditions

Stop on unexpected disk identity, wrong target repository, Talos bootstrap failure, Cilium failure, Flux source authentication failure, missing SOPS decryption key, External Secrets provider failure, or storage operator failure. Do not manually apply a Flux-managed workaround that Git will revert.

## Completion artifact

After bootstrap reaches a stable reconciliation boundary, write `handoff-status/05-bootstrap.yaml` in the target repository with authorization timestamp/reference (not credential data), nodes targeted, target commit, command exit results, Talos/Kubernetes versions, Flux source revision, failed gates if any, and `persistentDataRestored: false`. Commit it only if the target repository's policy permits operational status artifacts.
