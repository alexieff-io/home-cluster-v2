#!/usr/bin/env bash
set -euo pipefail

# Show per-node Talos/Kubernetes versions, readiness, and etcd membership.
# Useful before/after rolling Talos upgrades.
# Usage: ./scripts/check-cluster-health.sh

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TALENV="${REPO_ROOT}/talos/talenv.yaml"

TARGET_TALOS=$(awk -F': *' '/^talosVersion:/ {print $2}' "$TALENV" | tr -d '"')
TARGET_K8S=$(awk -F': *' '/^kubernetesVersion:/ {print $2}' "$TALENV" | tr -d '"')

echo "${BOLD}Target versions (from talenv.yaml):${RESET} talos=${TARGET_TALOS}  kubernetes=${TARGET_K8S}"
echo

NODES_JSON=$(kubectl get nodes -o json)

ROWS=()
while IFS=$'\t' read -r name ip status k8s; do
    talos_ver=$(talosctl -n "$ip" version 2>/dev/null \
        | awk '/^Server:/{flag=1; next} flag && /Tag:/{print $2; exit}' || true)
    talos_ver="${talos_ver:-?}"

    ready_color="$GREEN"
    [[ "$status" != "Ready" ]] && ready_color="$RED"

    talos_color="$GREEN"
    [[ "$talos_ver" != "$TARGET_TALOS" ]] && talos_color="$YELLOW"
    [[ "$talos_ver" == "?" ]] && talos_color="$RED"

    k8s_color="$GREEN"
    [[ "$k8s" != "$TARGET_K8S" ]] && k8s_color="$YELLOW"

    ROWS+=("${name}|${ip}|${ready_color}${status}${RESET}|${talos_color}${talos_ver}${RESET}|${k8s_color}${k8s}${RESET}")
done < <(echo "$NODES_JSON" | jq -r '
    .items[] |
    [
        .metadata.name,
        (.status.addresses[] | select(.type=="InternalIP") | .address),
        (.status.conditions[] | select(.type=="Ready") | (if .status=="True" then "Ready" else "NotReady" end)),
        .status.nodeInfo.kubeletVersion
    ] | @tsv
' | sort)

# Calculate column widths from the visible (uncolored) text.
strip_color() { printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*m//g'; }

MAX_NAME=4 MAX_IP=10 MAX_READY=6 MAX_TALOS=5 MAX_K8S=4
for row in "${ROWS[@]}"; do
    IFS='|' read -r c1 c2 c3 c4 c5 <<< "$row"
    (( ${#c1} > MAX_NAME )) && MAX_NAME=${#c1}
    (( ${#c2} > MAX_IP )) && MAX_IP=${#c2}
    plain=$(strip_color "$c3"); (( ${#plain} > MAX_READY )) && MAX_READY=${#plain}
    plain=$(strip_color "$c4"); (( ${#plain} > MAX_TALOS )) && MAX_TALOS=${#plain}
    plain=$(strip_color "$c5"); (( ${#plain} > MAX_K8S )) && MAX_K8S=${#plain}
done

printf "${BOLD}%-${MAX_NAME}s  %-${MAX_IP}s  %-${MAX_READY}s  %-${MAX_TALOS}s  %-${MAX_K8S}s${RESET}\n" \
    NODE IP STATUS TALOS K8S
printf '%0.s─' $(seq 1 $((MAX_NAME + MAX_IP + MAX_READY + MAX_TALOS + MAX_K8S + 8)))
echo

pad() {
    local text="$1" width="$2"
    local visible_len=${#3}
    local padding=$((width - visible_len))
    printf '%s%*s' "$text" "$padding" ''
}

for row in "${ROWS[@]}"; do
    IFS='|' read -r c1 c2 c3 c4 c5 <<< "$row"
    p3=$(strip_color "$c3"); p4=$(strip_color "$c4"); p5=$(strip_color "$c5")
    printf '%-*s  %-*s  ' "$MAX_NAME" "$c1" "$MAX_IP" "$c2"
    pad "$c3" "$MAX_READY" "$p3"; printf '  '
    pad "$c4" "$MAX_TALOS" "$p4"; printf '  '
    pad "$c5" "$MAX_K8S"   "$p5"; printf '\n'
done

echo
echo "${BOLD}Etcd members:${RESET}"

# Pick the first Ready node as the etcd query target.
QUERY_IP=$(echo "$NODES_JSON" | jq -r '
    [.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))][0]
    | .status.addresses[] | select(.type=="InternalIP") | .address
')

if [[ -n "$QUERY_IP" ]]; then
    if ! talosctl -n "$QUERY_IP" etcd members 2>/dev/null; then
        echo "${RED}failed to query etcd members via $QUERY_IP${RESET}"
    fi
else
    echo "${RED}no Ready node available to query etcd${RESET}"
fi
