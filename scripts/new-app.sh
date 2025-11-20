#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Helper functions
log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

prompt() {
    local var_name=$1
    local prompt_text=$2
    local default_value=${3:-}

    if [ -n "$default_value" ]; then
        read -p "$(echo -e "${BLUE}?${NC} $prompt_text [${default_value}]: ")" input
        eval "$var_name=\"${input:-$default_value}\""
    else
        read -p "$(echo -e "${BLUE}?${NC} $prompt_text: ")" input
        eval "$var_name=\"$input\""
    fi
}

confirm() {
    local prompt_text=$1
    local response
    read -p "$(echo -e "${YELLOW}?${NC} $prompt_text [y/N]: ")" response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Banner
echo -e "${BLUE}"
cat << 'EOF'
╔═══════════════════════════════════════════════════════╗
║                                                       ║
║     New Application Deployment Generator             ║
║                                                       ║
╚═══════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Change to repository root
cd "$REPO_ROOT"

# Collect information
log_info "Let's set up your new application..."
echo

prompt APP_NAME "Application name (lowercase, kebab-case)" ""
prompt NAMESPACE "Namespace" "default"
prompt IMAGE_REPO "Container image repository" "ghcr.io/myorg/${APP_NAME}"
prompt IMAGE_TAG "Container image tag" "latest"
prompt APP_PORT "Application port" "8080"
prompt HEALTH_PATH "Health check path" "/health"

echo
log_info "Configuration options:"
echo

if confirm "Does this app need external (internet) access?"; then
    NEEDS_INGRESS="external"
elif confirm "Does this app need internal cluster access?"; then
    NEEDS_INGRESS="internal"
else
    NEEDS_INGRESS="none"
fi

if confirm "Does this app need secrets from 1Password?"; then
    NEEDS_SECRETS=true
    prompt SECRET_NAME "Secret name in 1Password" "${APP_NAME}-secret"
else
    NEEDS_SECRETS=false
fi

if confirm "Does this app need persistent storage?"; then
    NEEDS_STORAGE=true
    prompt STORAGE_SIZE "Storage size (e.g., 10Gi)" "10Gi"
    prompt STORAGE_PATH "Mount path in container" "/data"
else
    NEEDS_STORAGE=false
fi

# Confirm settings
echo
log_info "Summary:"
echo "  App Name:      ${APP_NAME}"
echo "  Namespace:     ${NAMESPACE}"
echo "  Image:         ${IMAGE_REPO}:${IMAGE_TAG}"
echo "  Port:          ${APP_PORT}"
echo "  Health Path:   ${HEALTH_PATH}"
echo "  Ingress:       ${NEEDS_INGRESS}"
echo "  Secrets:       ${NEEDS_SECRETS}"
echo "  Storage:       ${NEEDS_STORAGE}"
echo

if ! confirm "Continue with these settings?"; then
    log_error "Aborted by user"
    exit 1
fi

# Create directory structure
APP_DIR="kubernetes/apps/${NAMESPACE}/${APP_NAME}"
APP_PATH="${APP_DIR}/app"

log_info "Creating directory structure..."
mkdir -p "$APP_PATH"
log_success "Created $APP_PATH"

# Check if namespace needs to be created
NAMESPACE_DIR="kubernetes/apps/${NAMESPACE}"
CREATE_NAMESPACE=false
if [ ! -f "${NAMESPACE_DIR}/namespace.yaml" ] && [ "$NAMESPACE" != "default" ]; then
    if confirm "Namespace ${NAMESPACE} doesn't exist. Create it?"; then
        CREATE_NAMESPACE=true
    fi
fi

# Generate ks.yaml
log_info "Generating Flux Kustomization..."
cat > "${APP_DIR}/ks.yaml" << EOF
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ${APP_NAME}
spec:
  interval: 1h
  path: ./kubernetes/apps/${NAMESPACE}/${APP_NAME}/app
  postBuild:
    substituteFrom:
      - name: cluster-secrets
        kind: Secret
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: ${NAMESPACE}
  wait: false
EOF
log_success "Created ks.yaml"

# Generate ocirepository.yaml
log_info "Generating OCIRepository..."
cat > "${APP_PATH}/ocirepository.yaml" << EOF
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: ${APP_NAME}
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 4.4.0
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
EOF
log_success "Created ocirepository.yaml"

# Generate helmrelease.yaml
log_info "Generating HelmRelease..."

# Start HelmRelease
cat > "${APP_PATH}/helmrelease.yaml" << EOF
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ${APP_NAME}
spec:
  chartRef:
    kind: OCIRepository
    name: ${APP_NAME}
  interval: 1h
  values:
    controllers:
      ${APP_NAME}:
        strategy: RollingUpdate
EOF

# Add reloader annotation if secrets are needed
if [ "$NEEDS_SECRETS" = true ]; then
    cat >> "${APP_PATH}/helmrelease.yaml" << EOF
        annotations:
          reloader.stakater.com/auto: "true"
EOF
fi

# Container configuration
cat >> "${APP_PATH}/helmrelease.yaml" << EOF
        containers:
          app:
            image:
              repository: ${IMAGE_REPO}
              tag: ${IMAGE_TAG}
            env:
              APP_PORT: &port ${APP_PORT}
EOF

# Add secrets if needed
if [ "$NEEDS_SECRETS" = true ]; then
    cat >> "${APP_PATH}/helmrelease.yaml" << EOF
            envFrom:
              - secretRef:
                  name: ${APP_NAME}-secret
EOF
fi

# Probes
cat >> "${APP_PATH}/helmrelease.yaml" << EOF
            probes:
              liveness: &probes
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: ${HEALTH_PATH}
                    port: *port
                  initialDelaySeconds: 10
                  periodSeconds: 10
                  timeoutSeconds: 1
                  failureThreshold: 3
              readiness: *probes
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities: { drop: ["ALL"] }
            resources:
              requests:
                cpu: 100m
                memory: 128Mi
              limits:
                memory: 512Mi
    defaultPodOptions:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
    service:
      app:
        ports:
          http:
            port: *port
EOF

# Add ingress if needed
if [ "$NEEDS_INGRESS" != "none" ]; then
    GATEWAY="envoy-external"
    if [ "$NEEDS_INGRESS" = "internal" ]; then
        GATEWAY="envoy-internal"
    fi

    cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    route:
      app:
        hostnames: ["${APP_NAME}.\${SECRET_DOMAIN}"]
        parentRefs:
          - name: ${GATEWAY}
            namespace: network
            sectionName: https
        rules:
          - backendRefs:
              - identifier: app
                port: *port
EOF
fi

# Add storage if needed
if [ "$NEEDS_STORAGE" = true ]; then
    cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    persistence:
      data:
        type: persistentVolumeClaim
        storageClass: local-path
        accessMode: ReadWriteOnce
        size: ${STORAGE_SIZE}
        globalMounts:
          - path: ${STORAGE_PATH}
      cache:
        type: emptyDir
        globalMounts:
          - path: /tmp/cache
EOF
fi

log_success "Created helmrelease.yaml"

# Generate externalsecret.yaml if needed
if [ "$NEEDS_SECRETS" = true ]; then
    log_info "Generating ExternalSecret..."
    cat > "${APP_PATH}/externalsecret.yaml" << EOF
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ${APP_NAME}-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: ${APP_NAME}-secret
    creationPolicy: Owner
  data:
    - secretKey: api-key
      remoteRef:
        key: ${SECRET_NAME}
        property: password
    # Add more secret keys as needed
    # - secretKey: another-key
    #   remoteRef:
    #     key: another-item
    #     property: password
EOF
    log_success "Created externalsecret.yaml"
fi

# Generate app kustomization.yaml
log_info "Generating app kustomization..."
cat > "${APP_PATH}/kustomization.yaml" << EOF
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
EOF

if [ "$NEEDS_SECRETS" = true ]; then
    echo "  - ./externalsecret.yaml" >> "${APP_PATH}/kustomization.yaml"
fi

log_success "Created app kustomization.yaml"

# Create namespace files if needed
if [ "$CREATE_NAMESPACE" = true ]; then
    log_info "Creating namespace files..."

    cat > "${NAMESPACE_DIR}/namespace.yaml" << EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
EOF

    cat > "${NAMESPACE_DIR}/kustomization.yaml" << EOF
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./namespace.yaml
  - ./${APP_NAME}/ks.yaml
EOF

    log_success "Created namespace files"
fi

# Update namespace kustomization
if [ -f "${NAMESPACE_DIR}/kustomization.yaml" ] && [ "$CREATE_NAMESPACE" = false ]; then
    log_info "Updating namespace kustomization..."

    # Check if app is already in kustomization
    if grep -q "./${APP_NAME}/ks.yaml" "${NAMESPACE_DIR}/kustomization.yaml"; then
        log_warning "App already exists in namespace kustomization"
    else
        # Add to resources
        if grep -q "^resources:" "${NAMESPACE_DIR}/kustomization.yaml"; then
            sed -i "/^resources:/a\\  - ./${APP_NAME}/ks.yaml" "${NAMESPACE_DIR}/kustomization.yaml"
        else
            echo "resources:" >> "${NAMESPACE_DIR}/kustomization.yaml"
            echo "  - ./${APP_NAME}/ks.yaml" >> "${NAMESPACE_DIR}/kustomization.yaml"
        fi
        log_success "Updated namespace kustomization"
    fi
fi

# Summary
echo
log_success "Application structure created successfully!"
echo
log_info "Next steps:"
echo
echo "1. Review and customize the generated files in:"
echo "   ${APP_DIR}/"
echo

if [ "$NEEDS_SECRETS" = true ]; then
    echo "2. Create secret in 1Password:"
    echo "   - Open 1Password and navigate to k8s_vault"
    echo "   - Create a new Password item named: ${SECRET_NAME}"
    echo "   - Add your secret values"
    echo
fi

echo "3. Commit and push changes:"
echo "   git add ${APP_DIR}/"
if [ "$CREATE_NAMESPACE" = true ]; then
    echo "   git add ${NAMESPACE_DIR}/namespace.yaml"
fi
if [ -f "${NAMESPACE_DIR}/kustomization.yaml" ]; then
    echo "   git add ${NAMESPACE_DIR}/kustomization.yaml"
fi
echo "   git commit -m \"feat: add ${APP_NAME} deployment\""
echo "   git push"
echo

echo "4. Apply to cluster (optional - Flux will auto-sync):"
echo "   flux reconcile kustomization cluster-apps -n flux-system"
echo

echo "5. Verify deployment:"
echo "   kubectl get helmrelease -n ${NAMESPACE} ${APP_NAME}"
echo "   kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=${APP_NAME}"

if [ "$NEEDS_SECRETS" = true ]; then
    echo "   kubectl get externalsecret -n ${NAMESPACE} ${APP_NAME}-secret"
fi

if [ "$NEEDS_INGRESS" != "none" ]; then
    echo "   kubectl get httproute -n ${NAMESPACE} ${APP_NAME}"
    echo
    echo "6. Access your application:"
    echo "   https://${APP_NAME}.\${SECRET_DOMAIN}"
fi

echo
log_info "For more details, see: docs/deploying-applications.md"
echo
