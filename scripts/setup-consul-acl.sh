#!/usr/bin/env bash
set -euo pipefail

# Setup Consul ACL agent tokens after deploying Consul to Kubernetes.
#
# Prerequisites:
#   1. consul CLI installed (https://developer.hashicorp.com/consul/install)
#   2. jq installed
#   3. kubectl configured with cluster access
#   4. 1Password item "consul-acl-token" exists with a "credential" field
#      containing the management token (a UUID you pre-generated).
#      This is used by the ExternalSecret to set initial_management.
#
# Usage:
#   ./scripts/setup-consul-acl.sh

CONSUL_LB_IP=$(kubectl -n network get svc consul -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export CONSUL_HTTP_ADDR="http://${CONSUL_LB_IP}:8500"

echo "Consul address: ${CONSUL_HTTP_ADDR}"
echo ""

# Read the management token from the k8s secret (synced from 1Password)
MGMT_TOKEN=$(kubectl -n network get secret consul-secret -o jsonpath='{.data.CONSUL_BOOTSTRAP_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [[ -z "${MGMT_TOKEN}" ]]; then
    echo "ERROR: Could not read management token from consul-secret."
    echo "Ensure the 1Password item 'consul-acl-token' has a 'credential' field"
    echo "and the ExternalSecret has synced successfully."
    exit 1
fi

export CONSUL_HTTP_TOKEN="${MGMT_TOKEN}"

# Verify connectivity
echo "Verifying Consul connectivity..."
consul members
echo ""

# Create policy for consul-sync (read-only service catalog access)
echo "=== Creating consul-sync policy ==="
consul acl policy create \
    -name "consul-sync" \
    -description "Read-only access for consul-sync controller" \
    -rules='
node_prefix "" { policy = "read" }
service_prefix "" { policy = "read" }
agent_prefix "" { policy = "read" }
' || echo "Policy 'consul-sync' already exists, skipping."

# Create token for consul-sync
echo ""
echo "=== Creating consul-sync token ==="
SYNC_TOKEN_OUTPUT=$(consul acl token create \
    -description "consul-sync controller" \
    -policy-name "consul-sync" \
    -format=json)
SYNC_TOKEN=$(echo "${SYNC_TOKEN_OUTPUT}" | jq -r '.SecretID')
echo "consul-sync token: ${SYNC_TOKEN}"

# Create policy for registrator (needs write to register/deregister services)
echo ""
echo "=== Creating registrator policy ==="
consul acl policy create \
    -name "registrator" \
    -description "Service registration for Docker Registrator" \
    -rules='
node_prefix "" { policy = "write" }
service_prefix "" { policy = "write" }
agent_prefix "" { policy = "write" }
' || echo "Policy 'registrator' already exists, skipping."

# Create token for registrator
echo ""
echo "=== Creating registrator token ==="
REG_TOKEN_OUTPUT=$(consul acl token create \
    -description "Docker Registrator" \
    -policy-name "registrator" \
    -format=json)
REG_TOKEN=$(echo "${REG_TOKEN_OUTPUT}" | jq -r '.SecretID')
echo "Registrator token: ${REG_TOKEN}"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Store consul-sync token in 1Password:"
echo "     Item: consul-acl-token  Field: password"
echo "     Value: ${SYNC_TOKEN}"
echo ""
echo "  2. Update Registrator docker-compose with token:"
echo "     CONSUL_TOKEN=${REG_TOKEN}"
echo ""
echo "  3. Wait for consul-sync ExternalSecret to sync, then restart consul-sync:"
echo "     kubectl -n network rollout restart deployment consul-sync"
