#!/usr/bin/env bash
set -euo pipefail

# Setup Consul ACL agent tokens after deploying Consul to Kubernetes.
#
# Prerequisites:
#   1. consul CLI installed (https://developer.hashicorp.com/consul/install)
#   2. jq installed
#   3. kubectl configured with cluster access (to look up LoadBalancer IP)
#
# Usage:
#   ./scripts/setup-consul-acl.sh <management-token>
#
#   The management token is the value you stored in 1Password
#   (consul-acl-token, credential field) before deploying Consul.

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <management-token>"
    echo ""
    echo "  management-token: The ACL bootstrap token from 1Password"
    echo "                    (consul-acl-token, credential field)"
    exit 1
fi

MGMT_TOKEN="$1"

CONSUL_LB_IP=$(kubectl -n network get svc consul -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export CONSUL_HTTP_ADDR="http://${CONSUL_LB_IP}:8500"
export CONSUL_HTTP_TOKEN="${MGMT_TOKEN}"

echo "Consul address: ${CONSUL_HTTP_ADDR}"
echo ""

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
