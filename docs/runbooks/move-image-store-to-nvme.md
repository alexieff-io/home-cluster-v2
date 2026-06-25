# Runbook: Move the container image store to NVMe

> **There is a guided script for this:** `scripts/move-image-store-to-nvme.sh <node-ip>`.
> It runs each step below for **one node**, verifies status between steps, and
> gates the destructive wipe behind an explicit typed confirmation. This document
> is the reference; the script is the recommended way to execute it.

## Why

Each node boots from a **31 GB SD/eMMC card** (`mmcblk0`). Its `EPHEMERAL`
partition (`mmcblk0p6`, ~29 GB) backs everything under `/var` except Longhorn —
including the **container image store** (`/var/lib/containerd`, ~15 GB), pod
ephemeral scratch, **and etcd**. That `/var` filesystem is also what the kubelet
measures as `imagefs`/`nodefs`.

When free space drops below the kubelet hard-eviction threshold the node reports
`DiskPressure` and evicts pods; independently, the SD card's low IOPS starve
etcd's WAL fsync, which has caused `etcd health check ... context deadline
exceeded` flaps and full no-leader outages (2026-06-06, and again on node3 on
2026-06-25). Moving `/var/lib/containerd` onto the 2 TB NVMe takes the largest
write source off the SD card, ending the imagefs pressure and giving etcd far
more headroom.

> This is the **interim mitigation**. It does *not* move etcd itself (etcd stays
> on the SD card `EPHEMERAL` partition). The full fix — a dedicated
> `/var/lib/etcd` NVMe partition — is the same disk-wipe procedure and can be
> folded into this pass by adding a third partition. See "Related".

## The change

`talos/patches/global/machine-disks.yaml` declares **two** NVMe partitions:

| mountpoint            | size      | purpose                         |
| --------------------- | --------- | ------------------------------- |
| `/var/lib/longhorn`   | `1800GiB` | Longhorn replica storage        |
| `/var/lib/containerd` | remainder | container image store (~200 GB) |

Previously the Longhorn partition had **no size**, so it claimed the whole 2 TB
disk. xfs cannot shrink in place, so applying this config to an
already-partitioned NVMe **requires wiping the disk** — which destroys that
node's Longhorn replicas. Longhorn replicates across nodes, so this is safe
**only when done one node at a time**, letting Longhorn rebuild each node's
replicas from the other three before proceeding.

## Pre-flight

- [ ] Cluster healthy: `kubectl get nodes`, all `Ready`.
- [ ] Longhorn: every volume `Healthy` at its configured replica count
      (`kubectl -n longhorn-system get volumes.longhorn.io`).
- [ ] This branch is merged to `main` **before** you start wiping nodes, so the
      generated Talos config reflects the new layout. (The reconcile is harmless
      on the still-single-partition nodes until each is wiped.)
- [ ] `task` / `talhelper` / `talosctl` / `kubectl` / `jq` available (`mise install`).
- [ ] A maintenance window: 4 drains, 4 reboots, and 4 Longhorn replica rebuilds.
      Rebuild time depends on how much replica data each node holds.

## Per-node procedure (repeat for 10.69.0.10 → .11 → .12 → .13)

Do **one node at a time.** Do not start the next node until the previous node's
Longhorn replicas are fully rebuilt. `IP` = node address, `NODE` = kubectl name.

1. **Pre-checks** — node `Ready`, all Longhorn volumes healthy, and **no volume
   has its only healthy replica on this node** (wiping would lose data).

2. **Cordon + drain.** Longhorn puts a PDB (`minAvailable: 1`) on every
   `instance-manager` pod; under the default `block-if-contains-last-replica`
   policy a plain `kubectl drain` hangs on `Cannot evict pod ... instance-manager`
   even when the node holds no last replica. Temporarily relax the drain policy
   (safe because pre-flight confirmed redundancy elsewhere), then restore it:
   ```bash
   kubectl cordon <NODE>
   orig=$(kubectl -n longhorn-system get settings.longhorn.io node-drain-policy -o jsonpath='{.value}')
   kubectl -n longhorn-system patch settings.longhorn.io node-drain-policy --type=merge -p '{"value":"always-allow"}'
   kubectl drain <NODE> --ignore-daemonsets --delete-emptydir-data --timeout=15m
   kubectl -n longhorn-system patch settings.longhorn.io node-drain-policy --type=merge -p "{\"value\":\"${orig}\"}"
   ```
   (The script does this automatically, restoring the policy even on failure.)

3. **Confirm Longhorn redundancy after drain** — no volume is
   degraded-without-redundancy. If a volume's only healthy replica was on this
   node, wait for it to rebuild elsewhere (or temporarily raise its replica
   count) before wiping.

4. **Wipe the NVMe and reboot** — wipes ONLY the user disk; the system disk
   (EPHEMERAL/STATE) is untouched, so the node rejoins the cluster. (Flags
   verified against `talosctl v1.13.4`.)
   ```bash
   talosctl -n <IP> reset \
     --wipe-mode user-disks \
     --user-disks-to-wipe /dev/nvme0n1 \
     --graceful --reboot
   ```

5. **Apply the config** so Talos creates the two partitions on the now-blank
   NVMe and mounts `/var/lib/containerd` there:
   ```bash
   task talos:apply-node IP=<IP>
   ```
   The node re-pulls images onto the new NVMe-backed `/var/lib/containerd`.

6. **Verify the layout**:
   ```bash
   talosctl -n <IP> get discoveredvolumes      # expect 2 nvme0n1 partitions
   kubectl get --raw "/api/v1/nodes/<NODE>/proxy/stats/summary" \
     | jq '.node.runtime.imageFs | {cap:.capacityBytes, avail:.availableBytes}'
   # imageFs capacity should now reflect the ~200 GB NVMe partition, not ~29 GB
   ```

7. **Uncordon**
   ```bash
   kubectl uncordon <NODE>
   ```

8. **Wait for Longhorn to fully rebuild** this node's replicas (all volumes
   `Healthy`) before moving to the next node.

## Verify (after all 4 nodes)

```bash
# Plenty of imagefs headroom on every node
for n in node1 node2 node3 node4; do
  kubectl get --raw "/api/v1/nodes/$n/proxy/stats/summary" \
    | jq -r "\"$n imagefs avail=\(.node.runtime.imageFs.availableBytes/1e9|floor)GB\""
done

# No DiskPressure, no fresh evictions
kubectl get nodes -o json | jq -r '.items[] | .metadata.name as $n
  | .status.conditions[] | select(.type=="DiskPressure") | "\($n) DiskPressure=\(.status)"'
kubectl get events -A --field-selector reason=Evicted
```

## Rollback

Revert the `machine-disks.yaml` change and repeat the per-node wipe+apply to
return the NVMe to a single full-disk Longhorn partition. (Image store falls
back to the SD card — i.e. back to the original constrained state.)

## Related

- **Planned etcd-on-NVMe split** — same disk constraint and same wipe procedure.
  To do both in one pass, add a third partition (e.g. `/var/lib/etcd`, 64GiB)
  to `machine-disks.yaml` before running the script. This is the durable fix for
  the etcd-on-SD-card IOPS starvation; the image-store move alone is mitigation.
