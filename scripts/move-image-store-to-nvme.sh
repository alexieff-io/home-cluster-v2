#!/usr/bin/env bash
set -Eeuo pipefail

# Guided, node-by-node migration of the container image store (/var/lib/containerd)
# onto the NVMe disk by repartitioning it. See docs/runbooks/move-image-store-to-nvme.md.
#
# Runs ONE node per invocation. Each step verifies status and the destructive
# NVMe wipe is gated behind a typed confirmation. Re-run for each node, waiting
# for Longhorn to rebuild between nodes.
#
# Usage:
#   ./scripts/move-image-store-to-nvme.sh <node-ip>     # e.g. 10.69.0.12
#   ./scripts/move-image-store-to-nvme.sh <node-ip> --yes-i-know   # skip step pauses (still confirms wipe)
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

# Pause between steps unless --yes-i-know was passed. The wipe has its own gate.
pause() {
    [[ "$AUTO" == "--yes-i-know" ]] && return 0
    printf "${YELLOW}» %s${RESET} [enter to continue, Ctrl-C to abort] " "$1"
    read -r _
}

# Hard confirmation: caller must type the exact token.
confirm_typed() {
    local token="$1" msg="$2" answer
    printf "${RED}${BOLD}%s${RESET}\n" "$msg"
    printf "Type ${BOLD}%s${RESET} to proceed: " "$token"
    read -r answer
    [[ "$answer" == "$token" ]] || log error "Confirmation did not match — aborting."
}

# ── resolve node ─────────────────────────────────────────────────────────────

NODE="$(kubectl get nodes -o json \
    | jq -r --arg ip "$IP" '.items[] | select(.status.addresses[]?.address==$ip) | .metadata.name')"
[[ -z "$NODE" ]] && log error "No Kubernetes node has InternalIP ${IP}." "ip=${IP}"

printf "\n${BOLD}Move image store → NVMe${RESET}  node=${BOLD}%s${RESET} ip=%s device=%s\n" \
    "$NODE" "$IP" "$WIPE_DEVICE"

# ── STEP 1: pre-flight ───────────────────────────────────────────────────────

step "1. Pre-flight checks"

ok=true

# 1a. All nodes Ready
not_ready="$(kubectl get nodes -o json \
    | jq -r '.items[] | select(any(.status.conditions[]; .type=="Ready" and .status!="True")) | .metadata.name')"
if [[ -z "$not_ready" ]]; then pass "all nodes Ready"; else fail "not Ready: ${not_ready}"; ok=false; fi

# 1b. Target node is Ready (we are about to drain it)
this_ready="$(kubectl get node "$NODE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')"
if [[ "$this_ready" == "True" ]]; then pass "${NODE} is Ready"; else fail "${NODE} not Ready (${this_ready})"; ok=false; fi

# 1c. No Longhorn volume is unhealthy right now
unhealthy="$(kubectl -n longhorn-system get volumes.longhorn.io -o json \
    | jq -r '[.items[] | select(.status.robustness!="healthy")] | length')"
if [[ "$unhealthy" == "0" ]]; then pass "all Longhorn volumes healthy"; else fail "${unhealthy} volume(s) not healthy — let them recover first"; ok=false; fi

# 1d. CRITICAL: no volume's only healthy replica lives on this node
at_risk="$(kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r --arg node "$NODE" '
    [.items[] | select((.spec.failedAt // "") == "")]
    | group_by(.spec.volumeName)
    | map({vol: .[0].spec.volumeName,
           total: length,
           elsewhere: (map(select(.spec.nodeID != $node)) | length),
           here: (map(select(.spec.nodeID == $node)) | length)})
    | map(select(.here > 0 and .elsewhere == 0))
    | .[].vol')"
if [[ -z "$at_risk" ]]; then
    pass "every volume with a replica here has another healthy replica elsewhere"
else
    fail "these volumes would LOSE their only healthy replica if ${NODE} is wiped:"
    printf "      ${RED}%s${RESET}\n" $at_risk
    ok=false
fi

# 1e. Confirm the target device is the expected NVMe (sanity vs wiping the wrong disk)
dev_size="$(talosctl -n "$IP" get disks -o json 2>/dev/null \
    | jq -r --arg d "$(basename "$WIPE_DEVICE")" 'select(.metadata.id==$d) | .spec.size' | head -1 || true)"
if [[ -n "$dev_size" ]]; then
    pass "found ${WIPE_DEVICE} on ${NODE} (size=$(( dev_size / 1000000000 )) GB)"
else
    fail "could not confirm ${WIPE_DEVICE} on ${NODE} via talosctl"; ok=false
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
note "draining (timeout ${DRAIN_TIMEOUT})…"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout="$DRAIN_TIMEOUT"
pass "drained"

# ── STEP 3: redundancy recheck after drain ───────────────────────────────────

step "3. Re-check Longhorn redundancy after drain"
sleep 5
degraded_no_redundancy="$(kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '
    [.items[] | select(.status.robustness=="faulted")] | .[].metadata.name')"
if [[ -z "$degraded_no_redundancy" ]]; then
    pass "no faulted volumes"
else
    fail "faulted volume(s) present — do NOT wipe until resolved:"
    printf "      ${RED}%s${RESET}\n" $degraded_no_redundancy
    log error "Aborting before wipe to protect data." "node=${NODE}"
fi
pause "Proceed to WIPE ${WIPE_DEVICE} on ${NODE}"

# ── STEP 4: wipe NVMe + reboot ───────────────────────────────────────────────

step "4. Wipe NVMe and reboot" "${NODE} ${WIPE_DEVICE}"
confirm_typed "$NODE" \
    "This will ERASE ${WIPE_DEVICE} on ${NODE} (${IP}), destroying its Longhorn replicas. The system disk is untouched; the node will reboot and rejoin."
note "issuing graceful reset (wipe user disk only)…"
talosctl -n "$IP" reset \
    --wipe-mode user-disks \
    --user-disks-to-wipe "$WIPE_DEVICE" \
    --graceful --reboot
pass "reset issued — node is rebooting"

# ── STEP 5: wait for node to rejoin ──────────────────────────────────────────

step "5. Wait for ${NODE} to rejoin"
note "waiting for ${NODE} to report Ready again (this includes reboot time)…"
for i in $(seq 1 60); do
    st="$(kubectl get node "$NODE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
    printf "\r  [%3ss] %s Ready=%s   " "$((i*10))" "$NODE" "${st:-?}"
    [[ "$st" == "True" ]] && { printf "\n"; pass "${NODE} rejoined and Ready"; break; }
    sleep 10
done
[[ "$(kubectl get node "$NODE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)" == "True" ]] \
    || log error "${NODE} did not become Ready within ~10m — investigate before continuing." "node=${NODE}"

# ── STEP 6: apply config (create new partitions) ─────────────────────────────

step "6. Apply Talos config" "${NODE}"
note "running: task talos:apply-node IP=${IP}"
pause "Apply config to create the two NVMe partitions"
task talos:apply-node IP="$IP"
pass "config applied"

# ── STEP 7: verify new layout ────────────────────────────────────────────────

step "7. Verify NVMe layout + imagefs"
sleep 10
parts="$(talosctl -n "$IP" get discoveredvolumes -o json 2>/dev/null \
    | jq -r 'select(.spec.type=="partition" and (.metadata.id | test("nvme0n1p"))) | .metadata.id' | sort -u || true)"
pcount="$(printf "%s\n" "$parts" | grep -c . || true)"
if [[ "$pcount" -ge 2 ]]; then pass "found ${pcount} NVMe partitions: $(echo $parts | tr '\n' ' ')"; else fail "expected 2 NVMe partitions, found ${pcount}"; fi

imgfs="$(kubectl get --raw "/api/v1/nodes/${NODE}/proxy/stats/summary" 2>/dev/null \
    | jq -r '.node.runtime.imageFs | "\((.capacityBytes/1e9)|floor)GB cap, \((.availableBytes/1e9)|floor)GB avail"' || true)"
if [[ -n "$imgfs" ]]; then
    note "imagefs: ${imgfs}  (expect cap ~200GB, not ~29GB)"
else
    note "imagefs stats not yet available (kubelet may still be settling)"
fi

# ── STEP 8: uncordon ─────────────────────────────────────────────────────────

step "8. Uncordon ${NODE}"
pause "Uncordon ${NODE} and let workloads schedule back"
kubectl uncordon "$NODE"
pass "uncordoned"

# ── STEP 9: wait for Longhorn rebuild ────────────────────────────────────────

step "9. Wait for Longhorn to rebuild replicas on ${NODE}"
note "Longhorn will rebuild this node's replicas from the other three."
note "Do NOT start the next node until all volumes are healthy again."
for i in $(seq 1 180); do
    unhealthy="$(kubectl -n longhorn-system get volumes.longhorn.io -o json 2>/dev/null \
        | jq -r '[.items[] | select(.status.robustness!="healthy")] | length' || echo "?")"
    printf "\r  [%4ss] volumes not healthy: %s   " "$((i*20))" "$unhealthy"
    [[ "$unhealthy" == "0" ]] && { printf "\n"; pass "all Longhorn volumes healthy"; break; }
    sleep 20
done

unhealthy="$(kubectl -n longhorn-system get volumes.longhorn.io -o json \
    | jq -r '[.items[] | select(.status.robustness!="healthy")] | length')"
printf "\n"
if [[ "$unhealthy" == "0" ]]; then
    printf "${GREEN}${BOLD}✔ ${NODE} done.${RESET} NVMe repartitioned, image store relocated, replicas rebuilt.\n"
    printf "Next: run this script for the next node (10.69.0.10 → .11 → .12 → .13).\n"
else
    log warn "${unhealthy} volume(s) still rebuilding — wait for 0 before the next node." "node=${NODE}"
fi
