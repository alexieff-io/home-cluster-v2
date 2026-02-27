#!/usr/bin/env bash
set -Eeuo pipefail

# Force resync all ExternalSecrets and track their status until completion.
#
# Prerequisites:
#   1. kubectl configured with cluster access
#   2. jq installed
#
# Usage:
#   ./scripts/resync-external-secrets.sh [options]
#
# Options:
#   -n, --namespace <ns>   Only resync secrets in this namespace
#   -s, --secret <name>    Only resync a specific ExternalSecret (requires -n)
#   -t, --timeout <secs>   Timeout in seconds waiting for sync (default: 120)
#   -w, --no-wait          Trigger resync but don't wait for completion
#   -v, --verbose          Enable debug logging

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- defaults ---
FILTER_NS=""
FILTER_SECRET=""
TIMEOUT=120
WAIT=true

# --- parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)  FILTER_NS="$2";     shift 2 ;;
        -s|--secret)     FILTER_SECRET="$2";  shift 2 ;;
        -t|--timeout)    TIMEOUT="$2";        shift 2 ;;
        -w|--no-wait)    WAIT=false;          shift   ;;
        -v|--verbose)    export LOG_LEVEL=debug; shift ;;
        -h|--help)
            sed -n '3,/^$/s/^# \?//p' "$0"
            exit 0
            ;;
        *) log error "Unknown option: $1" ;;
    esac
done

if [[ -n "${FILTER_SECRET}" && -z "${FILTER_NS}" ]]; then
    log error "--secret requires --namespace"
fi

check_cli kubectl jq

# --- discover ExternalSecrets ---
discover_secrets() {
    local ns_flag=("--all-namespaces")
    if [[ -n "${FILTER_NS}" ]]; then
        ns_flag=("-n" "${FILTER_NS}")
    fi

    local jq_filter='.items'
    if [[ -n "${FILTER_SECRET}" ]]; then
        jq_filter=".items | map(select(.metadata.name == \"${FILTER_SECRET}\"))"
    fi

    kubectl get externalsecrets "${ns_flag[@]}" -o json \
        | jq -r "${jq_filter} | .[] | \"\(.metadata.namespace)/\(.metadata.name)\""
}

# --- annotate to force sync ---
force_sync() {
    local ns="$1" name="$2"
    local ts
    ts=$(date +%s)
    kubectl -n "${ns}" annotate externalsecret "${name}" \
        force-sync="${ts}" --overwrite >/dev/null
}

# --- read current sync status ---
get_status() {
    local ns="$1" name="$2"
    kubectl -n "${ns}" get externalsecret "${name}" -o json \
        | jq -r '{
            ready: ((.status.conditions // []) | map(select(.type == "Ready")) | first // {} | .status // "Unknown"),
            message: ((.status.conditions // []) | map(select(.type == "Ready")) | first // {} | .message // ""),
            lastSync: (.status.refreshTime // "never")
        } | "\(.ready)|\(.message)|\(.lastSync)"'
}

# --- main ---
log info "Discovering ExternalSecrets..."

secrets=()
while IFS= read -r line; do
    [[ -n "${line}" ]] && secrets+=("${line}")
done < <(discover_secrets)

if [[ ${#secrets[@]} -eq 0 ]]; then
    log warn "No ExternalSecrets found"
    exit 0
fi

log info "Found ${#secrets[@]} ExternalSecret(s)"

# Record pre-sync refresh times so we can detect when a new sync completes
declare -A pre_sync_times
for entry in "${secrets[@]}"; do
    ns="${entry%%/*}"
    name="${entry##*/}"
    pre_sync_times["${entry}"]=$(kubectl -n "${ns}" get externalsecret "${name}" \
        -o jsonpath='{.status.refreshTime}' 2>/dev/null || echo "")
done

# Trigger force-sync on all secrets
for entry in "${secrets[@]}"; do
    ns="${entry%%/*}"
    name="${entry##*/}"
    log info "Triggering resync" "namespace=${ns}" "secret=${name}"
    force_sync "${ns}" "${name}"
done

if [[ "${WAIT}" != true ]]; then
    log info "Resync triggered for all secrets (--no-wait specified, skipping status tracking)"
    exit 0
fi

# --- wait & track ---
log info "Waiting for sync to complete (timeout: ${TIMEOUT}s)..."

declare -A completed
pending=${#secrets[@]}
start_time=$(date +%s)

# Column widths for aligned output
col_ns=20
col_name=35
col_status=8

print_header() {
    printf "\n  %-${col_ns}s %-${col_name}s %-${col_status}s %s\n" \
        "NAMESPACE" "NAME" "STATUS" "MESSAGE"
    printf "  %-${col_ns}s %-${col_name}s %-${col_status}s %s\n" \
        "$(printf '%0.s-' $(seq 1 ${col_ns}))" \
        "$(printf '%0.s-' $(seq 1 ${col_name}))" \
        "$(printf '%0.s-' $(seq 1 ${col_status}))" \
        "$(printf '%0.s-' $(seq 1 40))"
}

print_row() {
    local ns="$1" name="$2" status="$3" message="$4"
    local color="\033[0m"
    if [[ "${status}" == "Synced" ]]; then
        color="\033[32m" # green
    elif [[ "${status}" == "Failed" ]]; then
        color="\033[31m" # red
    else
        color="\033[33m" # yellow
    fi
    printf "  %-${col_ns}s %-${col_name}s ${color}%-${col_status}s\033[0m %s\n" \
        "${ns}" "${name}" "${status}" "${message}"
}

while [[ ${pending} -gt 0 ]]; do
    elapsed=$(( $(date +%s) - start_time ))
    if [[ ${elapsed} -ge ${TIMEOUT} ]]; then
        log warn "Timeout reached after ${TIMEOUT}s with ${pending} secret(s) still pending"
        break
    fi

    for entry in "${secrets[@]}"; do
        [[ -n "${completed[${entry}]:-}" ]] && continue

        ns="${entry%%/*}"
        name="${entry##*/}"
        status_line=$(get_status "${ns}" "${name}")

        IFS='|' read -r ready message last_sync <<< "${status_line}"

        # A secret is done syncing when its refreshTime changed from the pre-sync value
        if [[ "${last_sync}" != "${pre_sync_times[${entry}]}" ]]; then
            if [[ "${ready}" == "True" ]]; then
                completed["${entry}"]="Synced"
            else
                completed["${entry}"]="Failed"
            fi
            ((pending--))
            log debug "Secret synced" "namespace=${ns}" "secret=${name}" "ready=${ready}"
        fi
    done

    if [[ ${pending} -gt 0 ]]; then
        sleep 2
    fi
done

# --- summary ---
print_header

succeeded=0
failed=0
timed_out=0

for entry in "${secrets[@]}"; do
    ns="${entry%%/*}"
    name="${entry##*/}"
    status_line=$(get_status "${ns}" "${name}")
    IFS='|' read -r ready message _last_sync <<< "${status_line}"

    if [[ -n "${completed[${entry}]:-}" ]]; then
        if [[ "${completed[${entry}]}" == "Synced" ]]; then
            print_row "${ns}" "${name}" "Synced" "${message}"
            ((succeeded++))
        else
            print_row "${ns}" "${name}" "Failed" "${message}"
            ((failed++))
        fi
    else
        print_row "${ns}" "${name}" "Pending" "timed out waiting for sync"
        ((timed_out++))
    fi
done

echo ""
total=${#secrets[@]}
elapsed=$(( $(date +%s) - start_time ))
log info "Resync complete in ${elapsed}s" \
    "total=${total}" "synced=${succeeded}" "failed=${failed}" "timed_out=${timed_out}"

# Exit with error if any secrets failed or timed out
if [[ ${failed} -gt 0 || ${timed_out} -gt 0 ]]; then
    exit 1
fi
