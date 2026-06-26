# Runbook: Move etcd + container image store to NVMe

> **Guided script:** `scripts/move-etcd-image-store-to-nvme.sh <node-ip>`.
> It runs every step below for **one node**, verifies status between steps, and
> gates the destructive wipe behind a typed confirmation. This doc is the
> reference; the script is the recommended way to execute.

## Why

Each node boots from a **31 GB SD/eMMC card** (`mmcblk0`). Its `EPHEMERAL`
partition (`mmcblk0p6`, ~29 GB, mounted at `/var`) backs **etcd**
(`/var/lib/etcd`), the **container image store** (`/var/lib/containerd`), pod
scratch, and logs. The SD card's low IOPS starve etcd's WAL fsync, causing
`etcd health check ... context deadline exceeded` flaps and no-leader outages
(2026-06-06; node3 again 2026-06-25), and image pulls push `imagefs` toward the
kubelet eviction threshold.

This moves **both etcd and the image store** onto dedicated NVMe partitions, off
the SD card entirely. The SD card is then left with only the OS, config, and
light scratch — ending both the etcd IOPS starvation (the real sore point) and
the imagefs pressure.

## The change

`talos/patches/global/machine-disks.yaml` declares **three** NVMe partitions:

| mountpoint            | size      | purpose                       |
| --------------------- | --------- | ----------------------------- |
| `/var/lib/longhorn`   | `1700GiB` | Longhorn replica storage      |
| `/var/lib/etcd`       | `32GiB`   | etcd data directory           |
| `/var/lib/containerd` | remainder | container image store (~130GiB) |

The NVMe is ~1862 GiB usable; 1700 GiB Longhorn + 32 GiB etcd leaves ~130 GiB for
the image store. xfs can't shrink in place, so applying this to an
already-partitioned NVMe **requires wiping the disk** — destroying that node's
Longhorn replicas **and its etcd data**. Both re-sync from the other nodes, so
this is safe **only one node at a time** with healthy etcd quorum and Longhorn
redundancy.

> **node3 note:** node3 was migrated to a 2-partition layout (longhorn +
> containerd) on 2026-06-25 — its etcd is still on the SD card. Re-running this
> 3-partition procedure on node3 will move its etcd too.

## Pre-flight

- [ ] This branch merged to `main` (so generated config carries the layout).
- [ ] All nodes `Ready`; every Longhorn volume `Healthy`.
- [ ] etcd quorum healthy on all members: `talosctl -n <all-cp-ips> etcd status`.
- [ ] `task` / `talhelper` / `talosctl` / `kubectl` / `jq` available (`mise install`).
- [ ] Maintenance window: per node = drain + reboot + etcd re-sync + Longhorn rebuild.

## Per-node procedure (one at a time: 10.69.0.10 → .11 → .12 → .13)

Do **not** start the next node until the previous node's volumes are all
`Healthy` and etcd shows all members. `IP` = node address, `NODE` = kubectl name.

1. **Pre-flight:** node `Ready`, all volumes healthy, no volume's only replica on
   this node, and **etcd quorum holds without this node** (the other members must
   be healthy, since the wipe clears this node's etcd).

2. **Cordon + drain** — `--disable-eviction` bypasses the Longhorn
   instance-manager PDB (a plain drain hangs on it; `always-allow` doesn't
   reliably release it):
   ```bash
   kubectl cordon <NODE>
   kubectl drain <NODE> --ignore-daemonsets --delete-emptydir-data --disable-eviction --force --timeout=15m
   ```
   Volumes with a replica here go **degraded** (not faulted) — expected.

3. **Confirm no faulted volumes** before wiping.

4. **STAGE the config — before the wipe.** This is the critical ordering fix:
   ```bash
   task talos:generate-config
   task talos:apply-node IP=<IP> MODE=staged   # stage only, no reboot
   ```
   Staging first means the wipe+reboot provisions the new 3-partition layout on
   the blank disk in **one** reboot. Applying *after* the wipe (or with
   `--mode=auto`) wedges the node: it boots with the old layout, the new config
   then demands partitions the disk lacks, the `/etc/kubernetes` overlay fails to
   mount, and kubelet can't start (`bootstrap-kubeconfig: read-only file system`).

5. **Wipe NVMe + reboot** (`--graceful` leaves etcd cleanly first; flags verified
   on `talosctl v1.13.4`):
   ```bash
   talosctl -n <IP> reset --wipe-mode user-disks --user-disks-to-wipe /dev/nvme0n1 --graceful --reboot
   ```
   The node leaves etcd, reboots, provisions the 3 partitions, and re-syncs etcd
   from the other members.

6. **Wait for rejoin:** node `Ready`, and `talosctl -n <IP> etcd status` succeeds
   (member healthy + DB synced).

7. **Re-initialise the Longhorn disk.** The wiped `/var/lib/longhorn` has a new
   filesystem UUID, so Longhorn marks it not-ready
   (`DiskFilesystemChanged: record diskUUID doesn't match the one on the disk`,
   `ready=False max=0`). Remove and re-add the disk so Longhorn re-initialises it:
   ```bash
   N=<NODE>; D=$(kubectl -n longhorn-system get nodes.longhorn.io $N -o json | jq -r '.spec.disks|keys[0]')
   C=$(kubectl -n longhorn-system get nodes.longhorn.io $N -o json | jq -c --arg d "$D" '.spec.disks[$d]')
   # disable, confirm 0 replicas on node, remove (null), wait status clears, re-add:
   kubectl -n longhorn-system patch nodes.longhorn.io $N --type=merge -p "$(jq -nc --arg d "$D" --argjson c "$C" '{spec:{disks:{($d):($c+{allowScheduling:false})}}}')"
   kubectl -n longhorn-system patch nodes.longhorn.io $N --type=merge -p "$(jq -nc --arg d "$D" '{spec:{disks:{($d):null}}}')"
   kubectl -n longhorn-system patch nodes.longhorn.io $N --type=merge -p "$(jq -nc --arg d "$D" --argjson c "$C" '{spec:{disks:{($d):($c+{allowScheduling:true})}}}')"
   ```
   (The script does this automatically and idempotently.)

8. **Verify:** three `nvme0n1p*` partitions, and `/var/lib/etcd`,
   `/var/lib/containerd`, `/var/lib/longhorn` all on `nvme*`:
   ```bash
   talosctl -n <IP> get discoveredvolumes | grep nvme0n1p
   talosctl -n <IP> get mounts | grep -E '/var/lib/(etcd|containerd|longhorn)'
   kubectl get --raw "/api/v1/nodes/<NODE>/proxy/stats/summary" | jq '.node.runtime.imageFs'
   ```

9. **Uncordon:** `kubectl uncordon <NODE>`.

10. **Wait** for Longhorn to rebuild this node's replicas (all volumes `Healthy`)
    and `talosctl etcd status` to show all members, before the next node.

## Rollback

Revert `machine-disks.yaml` and repeat the per-node stage+wipe to return the NVMe
to a single full-disk Longhorn partition (etcd + image store fall back to the SD
card — the original constrained state).

## Related

- [[project_nvme_image_store_migration]] memory — gotchas learned doing node3.
- The image-store-only (2-partition) variant was the interim mitigation; this
  3-partition version is the durable fix that also relocates etcd.
