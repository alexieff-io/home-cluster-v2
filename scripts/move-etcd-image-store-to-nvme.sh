#!/usr/bin/env bash
set -Eeuo pipefail

# Guided, node-by-node migration of etcd (/var/lib/etcd) AND the container image
# store (/var/lib/containerd) off the SD-card EPHEMERAL partition onto dedicated
# NVMe partitions, by repartitioning the NVMe. See
# docs/runbooks/move-etcd-image-store-to-nvme.md.
#
# Runs ONE node per invocation. Each step verifies status; the destructive wipe is
# gated behind a typed confirmation. The wipe also clears THIS node's etcd data —
# it re-syncs from the other members on rejoin — so the other control-plane nodes
# MUST hold etcd quorum (pre-flight checks this). Re-run for each node, waiting for
# Longhorn rebuild AND etcd health between nodes.
#
# Usage:
#   ./scripts/move-etcd-image-store-to-nvme.sh <node-ip>            # e.g. 10.69.0.12
#   ./scripts/move-etcd-image-store-to-nvme.sh <node-ip> --yes-i-know  # skip step pauses (still confirms wipe)
#
# Env:
#   WIPE_DEVICE   disk to wipe        (default: /dev/nvme0n1)
#   DRAIN_TIMEOUT kubectl drain wait  (default: 15m)
#   LOG_LEVEL     debug|info|warn|error (default: info)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

WIPE_DEVICE="${WIPE_DEVICE:-/dev/nvme0n1}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-15m}"

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'

IP="${1:-}"
AUTO="${2:-}"
[[ -z "$IP" ]] && log error "Usage: $0 <node-ip> [--yes-i-know]"

check_cli kubectl talosctl jq task

# ── helpers ──────────────────────────────────────────────────────────────────

pass() { printf "  ${GREEN}✔${RESET} %s\n" "$1"; }
fail() { printf "  ${RED}x${RESET} %s\n" "$1"; }
note() { printf "  ${DIM}%s${RESET}\n" "$1"; }
step() { printf "\n${BOLD}── %s ${RESET}${DIM}%s${RESET}\n" "$1" "${2:-}"; }

pause() {
    [[ "$AUTO" == "--yes-i-know" ]] && return 0
    printf "${YELLOW}» %s${RESET} [enter to continue, Ctrl-C to abort] " "$1"
    read -r _
}

confirm_typed() {
    local token="$1" msg="$2" answer
    printf "${RED}${BOLD}%s${RESET}\n" "$msg"
    printf "Type ${BOLD}%s${RESET} to proceed: " "$token"
    read -r answer
    [[ "$answer" == "$token" ]] || log error "Confirmation did not match — aborting."
}

# Longhorn marks a wiped disk not-ready (DiskFilesystemChanged: the new empty
# filesystem has a different UUID than Longhorn's record). Re-initialise it by
# removing and re-adding the disk; Longhorn then writes a fresh UUID and rebuilds
# replicas from peers. Idempotent: no-op if the disk is already Ready.
fix_longhorn_disk() {
    local node="$1" disk cfg ready reps r s i
    disk="$(kubectl -n longhorn-system get nodes.longhorn.io "$node" -o json | jq -r '.spec.disks | keys[0] // empty')"
    [[ -z "$disk" ]] && { fail "no Longhorn disk on ${node}"; return 1; }

    ready="$(kubectl -n longhorn-system get nodes.longhorn.io "$node" -o json \
        | jq -r --arg d "$disk" '.status.diskStatus[$d].conditions[]? | select(.type=="Ready") | .status' 2>/dev/null || true)"
    if [[ "$ready" == "True" ]]; then pass "Longhorn disk ${disk} already ready"; return 0; fi

    note "Longhorn disk ${disk} not ready (expected after wipe: DiskFilesystemChanged) — re-initialising"
    cfg="$(kubectl -n longhorn-system get nodes.longhorn.io "$node" -o json | jq -c --arg d "$disk" '.spec.disks[$d]')"

    kubectl -n longhorn-system patch nodes.longhorn.io "$node" --type=merge \
        -p "$(jq -nc --arg d "$disk" --argjson c "$cfg" '{spec:{disks:{($d):($c+{allowScheduling:false})}}}')" >/dev/null

    reps="$(kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r --arg n "$node" '[.items[]|select(.spec.nodeID==$n)]|length')"
    [[ "$reps" != "0" ]] && { fail "${reps} replica(s) still on ${node} — refusing to re-init disk"; return 1; }

    kubectl -n longhorn-system patch nodes.longhorn.io "$node" --type=merge \
        -p "$(jq -nc --arg d "$disk" '{spec:{disks:{($d):null}}}')" >/dev/null
    for i in $(seq 1 15); do
        [[ "$(kubectl -n longhorn-system get nodes.longhorn.io "$node" -o json | jq -r '.status.diskStatus|length')" == "0" ]] && break
        sleep 4
    done

    kubectl -n longhorn-system patch nodes.longhorn.io "$node" --type=merge \
        -p "$(jq -nc --arg d "$disk" --argjson c "$cfg" '{spec:{disks:{($d):($c+{allowScheduling:true})}}}')" >/dev/null
    for i in $(seq 1 24); do
        r="$(kubectl -n longhorn-system get nodes.longhorn.io "$node" -o json | jq -r --arg d "$disk" '.status.diskStatus[$d].conditions[]?|select(.type=="Ready")|.status' 2>/dev/null || true)"
        s="$(kubectl -n longhorn-system get nodes.longhorn.io "$node" -o json | jq -r --arg d "$disk" '.status.diskStatus[$d].conditions[]?|select(.type=="Schedulable")|.status' 2>/dev/null || true)"
        printf "\r  [%3ss] disk ready=%s schedulable=%s   " "$((i*5))" "${r:-?}" "${s:-?}"
        [[ "$r" == "True" && "$s" == "True" ]] && { printf "\n"; pass "Longhorn disk re-initialised"; return 0; }
        sleep 5
    done
    printf "\n"; fail "Longhorn disk did not become ready — check manually"; return 1
}

# ── resolve node ─────────────────────────────────────────────────────────────

NODE="$(kubectl get nodes -o json \
    | jq -r --arg ip "$IP" '.items[] | select(.status.addresses[]?.address==$ip) | .metadata.name')"
[[ -z "$NODE" ]] && log error "No Kubernetes node has InternalIP ${IP}." "ip=${IP}"

printf "\n${BOLD}Move etcd + image store → NVMe${RESET}  node=${BOLD}%s${RESET} ip=%s device=%s\n" \
    "$NODE" "$IP" "$WIPE_DEVICE"

# ── STEP 1: pre-flight ───────────────────────────────────────────────────────

step "1. Pre-flight checks"
ok=true

# 1a. All nodes Ready
not_ready="$(kubectl get nodes -o json \
    | jq -r '.items[] | select(any(.status.conditions[]; .type=="Ready" and .status!="True")) | .metadata.name')"
if [[ -z "$not_ready" ]]; then pass "all nodes Ready"; else fail "not Ready: ${not_ready}"; ok=false; fi

# 1b. Target node Ready
this_ready="$(kubectl get node "$NODE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')"
if [[ "$this_ready" == "True" ]]; then pass "${NODE} is Ready"; else fail "${NODE} not Ready (${this_ready})"; ok=false; fi

# 1c. No unhealthy Longhorn volume
unhealthy="$(kubectl -n longhorn-system get volumes.longhorn.io -o json \
    | jq -r '[.items[] | select(.status.robustness!="healthy")] | length')"
if [[ "$unhealthy" == "0" ]]; then pass "all Longhorn volumes healthy"; else fail "${unhealthy} volume(s) not healthy — let them recover first"; ok=false; fi

# 1d. CRITICAL: no volume's only healthy replica is on this node
at_risk="$(kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r --arg node "$NODE" '
    [.items[] | select((.spec.failedAt // "") == "")]
    | group_by(.spec.volumeName)
    | map({vol: .[0].spec.volumeName,
           elsewhere: (map(select(.spec.nodeID != $node)) | length),
           here: (map(select(.spec.nodeID == $node)) | length)})
    | map(select(.here > 0 and .elsewhere == 0)) | .[].vol')"
if [[ -z "$at_risk" ]]; then
    pass "every volume with a replica here has another healthy replica elsewhere"
else
    fail "these volumes would LOSE their only healthy replica if ${NODE} is wiped:"
    printf "      ${RED}%s${RESET}\n" $at_risk
    ok=false
fi

# 1e. Confirm target device is the expected NVMe
dev_size="$(talosctl -n "$IP" get disks -o json 2>/dev/null \
    | jq -r --arg d "$(basename "$WIPE_DEVICE")" 'select(.metadata.id==$d) | .spec.size' | head -1 || true)"
if [[ -n "$dev_size" ]]; then
    pass "found ${WIPE_DEVICE} on ${NODE} (size=$(( dev_size / 1000000000 )) GB)"
else
    fail "could not confirm ${WIPE_DEVICE} on ${NODE} via talosctl"; ok=false
fi

# 1f. CRITICAL: etcd quorum holds without this node (wipe clears this node's etcd)
mapfile -t CP_IPS < <(kubectl get nodes -l node-role.kubernetes.io/control-plane -o json \
    | jq -r '.items[].status.addresses[]|select(.type=="InternalIP")|.address')
etcd_ok=0; others=0
for cp in "${CP_IPS[@]}"; do
    [[ "$cp" == "$IP" ]] && continue
    others=$((others+1))
    talosctl -n "$cp" etcd status >/dev/null 2>&1 && etcd_ok=$((etcd_ok+1))
done
quorum=$(( ${#CP_IPS[@]} / 2 + 1 ))
if (( etcd_ok >= quorum )); then
    pass "etcd quorum safe: ${etcd_ok}/${others} other members healthy (quorum needs ${quorum} of ${#CP_IPS[@]})"
else
    fail "etcd quorum NOT safe: only ${etcd_ok}/${others} other members healthy, need ${quorum} — do not wipe"; ok=false
fi

if [[ "$ok" != true ]]; then
    log error "Pre-flight failed — resolve the items above before proceeding." "node=${NODE}"
fi
note "Pre-flight clean."
pause "Proceed to cordon + drain ${NODE}"

# ── STEP 2: cordon + drain ───────────────────────────────────────────────────

step "2. Cordon + drain" "${NODE}"
kubectl cordon "$NODE"
pass "cordoned"

# Longhorn places a PDB (minAvailable=1) on every instance-manager pod and keeps it
# while the pod hosts running replicas, so a normal `kubectl drain` hangs on
# "Cannot evict pod ... instance-manager" (flipping node-drain-policy to
# always-allow does NOT reliably release it). --disable-eviction issues DELETE
# instead of the eviction API and bypasses the PDB. Data-safe: STEP 1d confirmed
# redundancy, and this node's replicas are about to be wiped and rebuilt anyway.
note "draining (timeout ${DRAIN_TIMEOUT}, --disable-eviction to bypass Longhorn instance-manager PDB)…"
kubectl drain "$NODE" \
    --ignore-daemonsets --delete-emptydir-data \
    --disable-eviction --force \
    --timeout="$DRAIN_TIMEOUT"
pass "drained"

# ── STEP 3: redundancy recheck after drain ───────────────────────────────────

step "3. Re-check Longhorn redundancy after drain"
sleep 5
faulted="$(kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '
    [.items[] | select(.status.robustness=="faulted")] | .[].metadata.name')"
if [[ -z "$faulted" ]]; then
    pass "no faulted volumes (degraded is expected and fine)"
else
    fail "faulted volume(s) present — do NOT wipe until resolved:"
    printf "      ${RED}%s${RESET}\n" $faulted
    log error "Aborting before wipe to protect data." "node=${NODE}"
fi

# ── STEP 4: STAGE the new disk config (BEFORE the wipe) ───────────────────────
# Order matters: the config must be staged first so that, after the wipe, the
# reboot provisions the new 3-partition layout on the blank disk in ONE reboot.
# Applying AFTER the wipe (or with --mode=auto) wedges the node: it boots with the
# old layout, the new config then demands partitions the disk lacks, the
# /etc/kubernetes overlay fails to mount, and kubelet can't start.

step "4. Stage new disk config" "${NODE} (talhelper --mode=staged)"
note "regenerating clusterconfig from talconfig + patches…"
( cd "${REPO_ROOT}/talos" && task talos:generate-config >/dev/null 2>&1 ) || task talos:generate-config
pause "Stage config on ${NODE} (no reboot yet)"
task talos:apply-node IP="$IP" MODE=staged
pass "config staged (applies on next boot)"

# ── STEP 5: wipe NVMe + reboot ───────────────────────────────────────────────

step "5. Wipe NVMe and reboot" "${NODE} ${WIPE_DEVICE}"
confirm_typed "$NODE" \
    "This ERASES ${WIPE_DEVICE} on ${NODE} (${IP}) — destroying its Longhorn replicas AND this node's etcd data. The SD-card system disk is untouched. With --graceful the node leaves etcd, reboots, provisions the 3-partition layout, and re-syncs etcd + Longhorn from the other nodes."
note "issuing graceful reset (leaves etcd, wipes user disk, reboots)…"
talosctl -n "$IP" reset \
    --wipe-mode user-disks \
    --user-disks-to-wipe "$WIPE_DEVICE" \
    --graceful --reboot
pass "reset issued — node is rebooting and provisioning the new layout"

# ── STEP 6: wait for node to rejoin (k8s Ready + etcd member healthy) ─────────

step "6. Wait for ${NODE} to rejoin (Kubernetes + etcd)"
note "waiting for ${NODE} Ready (includes reboot + disk provisioning)…"
for i in $(seq 1 90); do
    st="$(kubectl get node "$NODE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
    printf "\r  [%3ss] %s Ready=%s   " "$((i*10))" "$NODE" "${st:-?}"
    [[ "$st" == "True" ]] && { printf "\n"; pass "${NODE} Ready"; break; }
    sleep 10
done
[[ "$(kubectl get node "$NODE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)" == "True" ]] \
    || log error "${NODE} did not become Ready within ~15m — check 'talosctl -n ${IP} dmesg' before continuing." "node=${NODE}"
note "waiting for ${NODE} etcd member to be healthy + synced…"
for i in $(seq 1 30); do
    talosctl -n "$IP" etcd status >/dev/null 2>&1 && { pass "${NODE} etcd member healthy"; break; }
    printf "\r  [%3ss] etcd not yet healthy…   " "$((i*5))"
    sleep 5
done

# ── STEP 7: re-initialise Longhorn disk (DiskFilesystemChanged) ──────────────

step "7. Re-initialise Longhorn disk on ${NODE}"
fix_longhorn_disk "$NODE"

# ── STEP 8: verify new layout ────────────────────────────────────────────────

step "8. Verify NVMe layout (3 partitions: longhorn + etcd + containerd)"
sleep 5
parts="$(talosctl -n "$IP" get discoveredvolumes -o json 2>/dev/null \
    | jq -r 'select(.spec.type=="partition" and (.metadata.id | test("nvme0n1p"))) | .metadata.id' | sort -u || true)"
pcount="$(printf "%s\n" "$parts" | grep -c . || true)"
if [[ "$pcount" -ge 3 ]]; then pass "found ${pcount} NVMe partitions: $(echo $parts | tr '\n' ' ')"; else fail "expected 3 NVMe partitions, found ${pcount}"; fi

for mp in /var/lib/etcd /var/lib/containerd /var/lib/longhorn; do
    src="$(talosctl -n "$IP" get mounts 2>/dev/null | awk -v m="$mp" '$0 ~ (" "m"$") || $0 ~ (" "m" ") {print $6; exit}')"
    if printf "%s" "$src" | grep -q nvme; then pass "${mp} on NVMe (${src})"; else fail "${mp} NOT on NVMe (got '${src:-?}')"; fi
done

imgfs="$(kubectl get --raw "/api/v1/nodes/${NODE}/proxy/stats/summary" 2>/dev/null \
    | jq -r '.node.runtime.imageFs | "\((.capacityBytes/1e9)|floor)GB cap, \((.availableBytes/1e9)|floor)GB avail"' || true)"
[[ -n "$imgfs" ]] && note "imagefs: ${imgfs}  (NVMe partition, not the ~28GB SD card)"

# ── STEP 9: uncordon ─────────────────────────────────────────────────────────

step "9. Uncordon ${NODE}"
pause "Uncordon ${NODE} and let workloads schedule back"
kubectl uncordon "$NODE"
pass "uncordoned"

# ── STEP 10: wait for Longhorn rebuild ───────────────────────────────────────

step "10. Wait for Longhorn to rebuild replicas on ${NODE}"
note "Longhorn rebuilds this node's replicas from the others. Do NOT start the next"
note "node until all volumes are healthy AND etcd shows all members."
for i in $(seq 1 270); do
    unhealthy="$(kubectl -n longhorn-system get volumes.longhorn.io -o json 2>/dev/null \
        | jq -r '[.items[] | select(.status.robustness!="healthy")] | length' || echo "?")"
    printf "\r  [%5ss] volumes not healthy: %s   " "$((i*20))" "$unhealthy"
    [[ "$unhealthy" == "0" ]] && { printf "\n"; pass "all Longhorn volumes healthy"; break; }
    sleep 20
done

unhealthy="$(kubectl -n longhorn-system get volumes.longhorn.io -o json \
    | jq -r '[.items[] | select(.status.robustness!="healthy")] | length')"
printf "\n"
if [[ "$unhealthy" == "0" ]]; then
    printf "${GREEN}${BOLD}✔ ${NODE} done.${RESET} etcd + image store on NVMe, Longhorn replicas rebuilt.\n"
    printf "Verify etcd: ${DIM}talosctl -n %s,%s etcd status${RESET}\n" "${CP_IPS[0]}" "${CP_IPS[1]}"
    printf "Then run this script for the next node (one at a time).\n"
else
    log warn "${unhealthy} volume(s) still rebuilding — wait for 0 before the next node." "node=${NODE}"
fi
