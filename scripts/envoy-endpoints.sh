#!/usr/bin/env bash
set -euo pipefail

# Show all HTTPRoutes and their backing EndpointSlices in a table.
# Usage: ./scripts/envoy-endpoints.sh [namespace]

NS="${1:-}"
NS_FLAG=(-A)
if [[ -n "$NS" ]]; then
    NS_FLAG=(-n "$NS")
fi

# Get all HTTPRoutes as JSON
ROUTES=$(kubectl get httproute "${NS_FLAG[@]}" -o json 2>/dev/null)
COUNT=$(echo "$ROUTES" | jq '.items | length')

if [[ "$COUNT" -eq 0 ]]; then
    echo "No HTTPRoutes found."
    exit 0
fi

# Build rows: NAMESPACE | HOSTNAME | GATEWAY | STATUS | ENDPOINTS
ROWS=()
while IFS=$'\t' read -r ns name; do
    ROUTE_JSON=$(echo "$ROUTES" | jq --arg ns "$ns" --arg name "$name" \
        '.items[] | select(.metadata.namespace == $ns and .metadata.name == $name)')

    HOSTNAME=$(echo "$ROUTE_JSON" | jq -r '(.spec.hostnames // [])[0] // "-"')
    GATEWAY=$(echo "$ROUTE_JSON" | jq -r '.spec.parentRefs[0].name // "-"')
    ACCEPTED=$(echo "$ROUTE_JSON" | jq -r \
        '(.status.parents // [])[0].conditions[]? | select(.type == "Accepted") | .status' 2>/dev/null || echo "?")

    BACKENDS=$(echo "$ROUTE_JSON" | jq -r '.spec.rules[]?.backendRefs[]? | "\(.name):\(.port)"')

    if [[ -z "$BACKENDS" ]]; then
        ROWS+=("${ns}|${HOSTNAME}|${GATEWAY}|${ACCEPTED}|-")
        continue
    fi

    while IFS=: read -r svc_name svc_port; do
        SLICES=$(kubectl -n "$ns" get endpointslice -l "kubernetes.io/service-name=$svc_name" -o json 2>/dev/null)
        ADDRS=$(echo "$SLICES" | jq -r '[.items[]?.endpoints[]? | select(.conditions.ready != false) | .addresses[]?] | unique | map(. + ":'"$svc_port"'") | join(", ")' 2>/dev/null)
        NOT_READY=$(echo "$SLICES" | jq -r '[.items[]?.endpoints[]? | select(.conditions.ready == false) | .addresses[]?] | unique | map(. + ":'"$svc_port"' (!)") | join(", ")' 2>/dev/null)

        EP_STR="${ADDRS:-none}"
        if [[ -n "$NOT_READY" ]]; then
            [[ "$EP_STR" == "none" ]] && EP_STR="$NOT_READY" || EP_STR="$EP_STR, $NOT_READY"
        fi
        [[ -z "$EP_STR" ]] && EP_STR="none"

        ROWS+=("${ns}|${HOSTNAME}|${GATEWAY}|${ACCEPTED}|${EP_STR}")
    done <<< "$BACKENDS"
done < <(echo "$ROUTES" | jq -r '.items[] | [.metadata.namespace, .metadata.name] | @tsv' | sort)

# Calculate column widths
HEADER="NAMESPACE|HOSTNAME|GATEWAY|OK|ENDPOINTS"
MAX_NS=9 MAX_HOST=8 MAX_GW=7 MAX_OK=2 MAX_EP=9

for row in "${ROWS[@]}"; do
    IFS='|' read -r c1 c2 c3 c4 c5 <<< "$row"
    (( ${#c1} > MAX_NS )) && MAX_NS=${#c1}
    (( ${#c2} > MAX_HOST )) && MAX_HOST=${#c2}
    (( ${#c3} > MAX_GW )) && MAX_GW=${#c3}
    (( ${#c4} > MAX_OK )) && MAX_OK=${#c4}
    (( ${#c5} > MAX_EP )) && MAX_EP=${#c5}
done

FMT="%-${MAX_NS}s  %-${MAX_HOST}s  %-${MAX_GW}s  %-${MAX_OK}s  %s\n"

# Print header
printf "\033[1m${FMT}\033[0m" "NAMESPACE" "HOSTNAME" "GATEWAY" "OK" "ENDPOINTS"
printf "%0.s─" $(seq 1 $((MAX_NS + MAX_HOST + MAX_GW + MAX_OK + MAX_EP + 8)))
echo

# Print rows
for row in "${ROWS[@]}"; do
    IFS='|' read -r c1 c2 c3 c4 c5 <<< "$row"
    # Color endpoints
    if [[ "$c5" == "none" ]]; then
        EP="\033[31m${c5}\033[0m"
    elif [[ "$c5" == *"(!)"* ]]; then
        EP="\033[33m${c5}\033[0m"
    else
        EP="\033[32m${c5}\033[0m"
    fi
    printf "%-${MAX_NS}s  %-${MAX_HOST}s  %-${MAX_GW}s  %-${MAX_OK}s  ${EP}\n" "$c1" "$c2" "$c3" "$c4"
done
