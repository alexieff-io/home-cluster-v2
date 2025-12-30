#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
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

select_option() {
    local prompt_text=$1
    shift
    local options=("$@")

    echo -e "${MAGENTA}?${NC} $prompt_text"
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[$i]}"
    done

    while true; do
        read -p "$(echo -e "${BLUE}Select [1-${#options[@]}]:${NC} ")" selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#options[@]}" ]; then
            echo "${options[$((selection-1))]}"
            return 0
        else
            log_error "Invalid selection. Please enter a number between 1 and ${#options[@]}"
        fi
    done
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

# Collect basic information
log_info "Let's set up your new application..."
echo

prompt APP_NAME "Application name (lowercase, kebab-case)" ""
prompt NAMESPACE "Namespace" "default"

# Chart type selection
echo
CHART_TYPE=$(select_option "Select deployment type:" \
    "App Template (bjw-s) - Best for custom apps" \
    "PostgreSQL - Bitnami PostgreSQL database" \
    "Redis - Bitnami Redis cache" \
    "MySQL/MariaDB - Bitnami MariaDB database" \
    "MongoDB - Bitnami MongoDB database" \
    "Custom OCI Chart - Specify OCI registry URL" \
    "Custom Helm Repo - Specify Helm repository")

case "$CHART_TYPE" in
    *"App Template"*)
        DEPLOYMENT_TYPE="app-template"
        ;;
    *"PostgreSQL"*)
        DEPLOYMENT_TYPE="postgresql"
        ;;
    *"Redis"*)
        DEPLOYMENT_TYPE="redis"
        ;;
    *"MySQL/MariaDB"*)
        DEPLOYMENT_TYPE="mariadb"
        ;;
    *"MongoDB"*)
        DEPLOYMENT_TYPE="mongodb"
        ;;
    *"Custom OCI"*)
        DEPLOYMENT_TYPE="custom-oci"
        ;;
    *"Custom Helm"*)
        DEPLOYMENT_TYPE="custom-helm"
        ;;
esac

log_info "Selected: ${DEPLOYMENT_TYPE}"
echo

# Collect deployment-specific information
case "$DEPLOYMENT_TYPE" in
    app-template)
        prompt IMAGE_REPO "Container image repository" "ghcr.io/myorg/${APP_NAME}"
        prompt IMAGE_TAG "Container image tag" "latest"
        prompt APP_PORT "Application port" "8080"
        prompt HEALTH_PATH "Health check path" "/health"
        ;;

    postgresql)
        prompt POSTGRES_USER "PostgreSQL username" "${APP_NAME}"
        prompt POSTGRES_DB "PostgreSQL database name" "${APP_NAME}"
        if confirm "Enable PostgreSQL metrics?"; then
            POSTGRES_METRICS=true
        else
            POSTGRES_METRICS=false
        fi
        ;;

    redis)
        if confirm "Enable Redis authentication?"; then
            REDIS_AUTH=true
        else
            REDIS_AUTH=false
        fi
        REDIS_ARCHITECTURE=$(select_option "Redis architecture:" "standalone" "replication")
        if confirm "Enable Redis metrics?"; then
            REDIS_METRICS=true
        else
            REDIS_METRICS=false
        fi
        ;;

    mariadb)
        prompt MARIADB_USER "MariaDB username" "${APP_NAME}"
        prompt MARIADB_DB "MariaDB database name" "${APP_NAME}"
        if confirm "Enable MariaDB metrics?"; then
            MARIADB_METRICS=true
        else
            MARIADB_METRICS=false
        fi
        ;;

    mongodb)
        prompt MONGODB_USER "MongoDB username" "${APP_NAME}"
        prompt MONGODB_DB "MongoDB database name" "${APP_NAME}"
        if confirm "Enable MongoDB metrics?"; then
            MONGODB_METRICS=true
        else
            MONGODB_METRICS=false
        fi
        ;;

    custom-oci)
        prompt CHART_OCI_URL "OCI chart URL (e.g., oci://registry/path/chart)" ""
        prompt CHART_VERSION "Chart version" "latest"
        log_warning "You'll need to manually configure values in helmrelease.yaml"
        ;;

    custom-helm)
        prompt CHART_REPO_URL "Helm repository URL" ""
        prompt CHART_NAME "Chart name" "${APP_NAME}"
        prompt CHART_VERSION "Chart version" "latest"
        log_warning "You'll need to manually configure values in helmrelease.yaml"
        ;;
esac

# Common configuration options
echo
log_info "Common configuration options:"
echo

# Ingress (only for app-template and web-facing services)
if [ "$DEPLOYMENT_TYPE" = "app-template" ]; then
    if confirm "Does this app need external (internet) access?"; then
        NEEDS_INGRESS="external"
    elif confirm "Does this app need internal cluster access?"; then
        NEEDS_INGRESS="internal"
    else
        NEEDS_INGRESS="none"
    fi
else
    # For databases, default to internal or none
    if confirm "Expose this service internally (HTTPRoute)?"; then
        NEEDS_INGRESS="internal"
    else
        NEEDS_INGRESS="none"
    fi
fi

# Secrets
if confirm "Does this deployment need secrets from 1Password?"; then
    NEEDS_SECRETS=true
    prompt SECRET_NAME "Secret name in 1Password" "${APP_NAME}-secret"

    # Ask for secret keys
    SECRET_KEYS=()
    while true; do
        prompt SECRET_KEY "Secret key name (leave empty to finish)" ""
        if [ -z "$SECRET_KEY" ]; then
            break
        fi
        prompt SECRET_1P_ITEM "1Password item name for ${SECRET_KEY}" "${SECRET_NAME}"
        prompt SECRET_1P_FIELD "1Password field name" "password"
        SECRET_KEYS+=("${SECRET_KEY}|${SECRET_1P_ITEM}|${SECRET_1P_FIELD}")
    done

    # If no keys specified, add default
    if [ ${#SECRET_KEYS[@]} -eq 0 ]; then
        case "$DEPLOYMENT_TYPE" in
            postgresql|mariadb|mongodb)
                SECRET_KEYS+=("password|${SECRET_NAME}|password")
                ;;
            redis)
                if [ "$REDIS_AUTH" = true ]; then
                    SECRET_KEYS+=("password|${SECRET_NAME}|password")
                fi
                ;;
            *)
                SECRET_KEYS+=("api-key|${SECRET_NAME}|password")
                ;;
        esac
    fi
else
    NEEDS_SECRETS=false
fi

# Storage
if confirm "Does this deployment need persistent storage?"; then
    NEEDS_STORAGE=true
    case "$DEPLOYMENT_TYPE" in
        postgresql|mariadb|mongodb|redis)
            prompt STORAGE_SIZE "Storage size" "10Gi"
            ;;
        *)
            prompt STORAGE_SIZE "Storage size" "10Gi"
            prompt STORAGE_PATH "Mount path in container" "/data"
            ;;
    esac
else
    NEEDS_STORAGE=false
fi

# Confirm settings
echo
log_info "Summary:"
echo "  App Name:      ${APP_NAME}"
echo "  Namespace:     ${NAMESPACE}"
echo "  Type:          ${DEPLOYMENT_TYPE}"
case "$DEPLOYMENT_TYPE" in
    app-template)
        echo "  Image:         ${IMAGE_REPO}:${IMAGE_TAG}"
        echo "  Port:          ${APP_PORT}"
        echo "  Health Path:   ${HEALTH_PATH}"
        ;;
    postgresql)
        echo "  User:          ${POSTGRES_USER}"
        echo "  Database:      ${POSTGRES_DB}"
        echo "  Metrics:       ${POSTGRES_METRICS}"
        ;;
    redis)
        echo "  Architecture:  ${REDIS_ARCHITECTURE}"
        echo "  Auth:          ${REDIS_AUTH}"
        echo "  Metrics:       ${REDIS_METRICS}"
        ;;
    mariadb)
        echo "  User:          ${MARIADB_USER}"
        echo "  Database:      ${MARIADB_DB}"
        echo "  Metrics:       ${MARIADB_METRICS}"
        ;;
    mongodb)
        echo "  User:          ${MONGODB_USER}"
        echo "  Database:      ${MONGODB_DB}"
        echo "  Metrics:       ${MONGODB_METRICS}"
        ;;
esac
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

# Generate chart source (OCIRepository or HelmRepository)
log_info "Generating chart source..."

case "$DEPLOYMENT_TYPE" in
    app-template)
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
        CHART_SOURCE_KIND="OCIRepository"
        ;;

    postgresql|redis|mariadb|mongodb)
        cat > "${APP_PATH}/helmrepository.yaml" << EOF
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: bitnami
spec:
  interval: 1h
  url: https://charts.bitnami.com/bitnami
EOF
        CHART_SOURCE_KIND="HelmRepository"
        CHART_SOURCE_NAME="bitnami"
        ;;

    custom-oci)
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
    tag: ${CHART_VERSION}
  url: ${CHART_OCI_URL}
EOF
        CHART_SOURCE_KIND="OCIRepository"
        ;;

    custom-helm)
        cat > "${APP_PATH}/helmrepository.yaml" << EOF
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: ${APP_NAME}-repo
spec:
  interval: 1h
  url: ${CHART_REPO_URL}
EOF
        CHART_SOURCE_KIND="HelmRepository"
        CHART_SOURCE_NAME="${APP_NAME}-repo"
        ;;
esac

log_success "Created chart source file"

# Generate helmrelease.yaml based on deployment type
log_info "Generating HelmRelease..."

case "$DEPLOYMENT_TYPE" in
    app-template)
        # App Template HelmRelease (existing logic)
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

        if [ "$NEEDS_SECRETS" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
        annotations:
          reloader.stakater.com/auto: "true"
EOF
        fi

        cat >> "${APP_PATH}/helmrelease.yaml" << EOF
        containers:
          app:
            image:
              repository: ${IMAGE_REPO}
              tag: ${IMAGE_TAG}
            env:
              APP_PORT: &port ${APP_PORT}
EOF

        if [ "$NEEDS_SECRETS" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
            envFrom:
              - secretRef:
                  name: ${APP_NAME}-secret
EOF
        fi

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
        ;;

    postgresql)
        cat > "${APP_PATH}/helmrelease.yaml" << EOF
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ${APP_NAME}
spec:
  chart:
    spec:
      chart: postgresql
      version: 16.x
      sourceRef:
        kind: HelmRepository
        name: bitnami
  interval: 1h
  values:
    auth:
      username: ${POSTGRES_USER}
      database: ${POSTGRES_DB}
EOF

        if [ "$NEEDS_SECRETS" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
      existingSecret: ${APP_NAME}-secret
      secretKeys:
        adminPasswordKey: postgres-password
        userPasswordKey: password
EOF
        else
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
      password: changeme
      postgresPassword: changeme
EOF
        fi

        if [ "$NEEDS_STORAGE" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    primary:
      persistence:
        enabled: true
        storageClass: local-path
        size: ${STORAGE_SIZE}
EOF
        else
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    primary:
      persistence:
        enabled: false
EOF
        fi

        if [ "$POSTGRES_METRICS" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
EOF
        fi
        ;;

    redis)
        cat > "${APP_PATH}/helmrelease.yaml" << EOF
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ${APP_NAME}
spec:
  chart:
    spec:
      chart: redis
      version: 20.x
      sourceRef:
        kind: HelmRepository
        name: bitnami
  interval: 1h
  values:
    architecture: ${REDIS_ARCHITECTURE}
    auth:
      enabled: ${REDIS_AUTH}
EOF

        if [ "$REDIS_AUTH" = true ] && [ "$NEEDS_SECRETS" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
      existingSecret: ${APP_NAME}-secret
      existingSecretPasswordKey: password
EOF
        fi

        if [ "$NEEDS_STORAGE" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    master:
      persistence:
        enabled: true
        storageClass: local-path
        size: ${STORAGE_SIZE}
EOF
        else
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    master:
      persistence:
        enabled: false
EOF
        fi

        if [ "$REDIS_METRICS" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
EOF
        fi
        ;;

    mariadb)
        cat > "${APP_PATH}/helmrelease.yaml" << EOF
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ${APP_NAME}
spec:
  chart:
    spec:
      chart: mariadb
      version: 20.x
      sourceRef:
        kind: HelmRepository
        name: bitnami
  interval: 1h
  values:
    auth:
      username: ${MARIADB_USER}
      database: ${MARIADB_DB}
EOF

        if [ "$NEEDS_SECRETS" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
      existingSecret: ${APP_NAME}-secret
      secretKeys:
        rootPasswordKey: mariadb-root-password
        userPasswordKey: password
EOF
        else
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
      password: changeme
      rootPassword: changeme
EOF
        fi

        if [ "$NEEDS_STORAGE" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    primary:
      persistence:
        enabled: true
        storageClass: local-path
        size: ${STORAGE_SIZE}
EOF
        else
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    primary:
      persistence:
        enabled: false
EOF
        fi

        if [ "$MARIADB_METRICS" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
EOF
        fi
        ;;

    mongodb)
        cat > "${APP_PATH}/helmrelease.yaml" << EOF
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ${APP_NAME}
spec:
  chart:
    spec:
      chart: mongodb
      version: 16.x
      sourceRef:
        kind: HelmRepository
        name: bitnami
  interval: 1h
  values:
    auth:
      usernames:
        - ${MONGODB_USER}
      databases:
        - ${MONGODB_DB}
EOF

        if [ "$NEEDS_SECRETS" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
      existingSecret: ${APP_NAME}-secret
      secretKeys:
        rootPasswordKey: mongodb-root-password
        userPasswordKey: password
EOF
        else
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
      passwords:
        - changeme
      rootPassword: changeme
EOF
        fi

        if [ "$NEEDS_STORAGE" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    persistence:
      enabled: true
      storageClass: local-path
      size: ${STORAGE_SIZE}
EOF
        else
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    persistence:
      enabled: false
EOF
        fi

        if [ "$MONGODB_METRICS" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
EOF
        fi
        ;;

    custom-*)
        # Basic template for custom charts
        cat > "${APP_PATH}/helmrelease.yaml" << EOF
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ${APP_NAME}
spec:
EOF

        if [ "$DEPLOYMENT_TYPE" = "custom-oci" ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
  chartRef:
    kind: OCIRepository
    name: ${APP_NAME}
EOF
        else
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
  chart:
    spec:
      chart: ${CHART_NAME}
      version: ${CHART_VERSION}
      sourceRef:
        kind: HelmRepository
        name: ${CHART_SOURCE_NAME}
EOF
        fi

        cat >> "${APP_PATH}/helmrelease.yaml" << EOF
  interval: 1h
  values:
    # TODO: Add chart-specific values here
    # Refer to the chart's documentation for available options
EOF

        if [ "$NEEDS_SECRETS" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    # Example: Using secrets
    # existingSecret: ${APP_NAME}-secret
EOF
        fi

        if [ "$NEEDS_STORAGE" = true ]; then
            cat >> "${APP_PATH}/helmrelease.yaml" << EOF
    # Example: Persistence
    # persistence:
    #   enabled: true
    #   storageClass: local-path
    #   size: ${STORAGE_SIZE}
EOF
        fi
        ;;
esac

log_success "Created helmrelease.yaml"

# Generate externalsecret.yaml if needed
if [ "$NEEDS_SECRETS" = true ]; then
    log_info "Generating ExternalSecret..."
    cat > "${APP_PATH}/externalsecret.yaml" << EOF
---
apiVersion: external-secrets.io/v1
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
EOF

    for secret_entry in "${SECRET_KEYS[@]}"; do
        IFS='|' read -r key item field <<< "$secret_entry"
        cat >> "${APP_PATH}/externalsecret.yaml" << EOF
    - secretKey: ${key}
      remoteRef:
        key: ${item}
        property: ${field}
EOF
    done

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
EOF

case "$DEPLOYMENT_TYPE" in
    app-template|custom-oci)
        echo "  - ./ocirepository.yaml" >> "${APP_PATH}/kustomization.yaml"
        ;;
    *)
        echo "  - ./helmrepository.yaml" >> "${APP_PATH}/kustomization.yaml"
        ;;
esac

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

    if grep -q "./${APP_NAME}/ks.yaml" "${NAMESPACE_DIR}/kustomization.yaml"; then
        log_warning "App already exists in namespace kustomization"
    else
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
    echo "2. Create secrets in 1Password:"
    echo "   - Open 1Password and navigate to k8s_vault"
    for secret_entry in "${SECRET_KEYS[@]}"; do
        IFS='|' read -r key item field <<< "$secret_entry"
        echo "   - Create/update item: ${item}"
        echo "     Field: ${field} → Secret key: ${key}"
    done
    echo
fi

if [[ "$DEPLOYMENT_TYPE" == custom-* ]]; then
    log_warning "Custom chart detected!"
    echo "   - Review helmrelease.yaml and add chart-specific values"
    echo "   - Consult the chart's documentation for configuration options"
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
log_info "Deployment type: ${DEPLOYMENT_TYPE}"
case "$DEPLOYMENT_TYPE" in
    postgresql)
        echo
        log_info "PostgreSQL connection info:"
        echo "   Host: ${APP_NAME}.${NAMESPACE}.svc.cluster.local"
        echo "   Port: 5432"
        echo "   Database: ${POSTGRES_DB}"
        echo "   Username: ${POSTGRES_USER}"
        if [ "$NEEDS_SECRETS" = true ]; then
            echo "   Password: (from 1Password secret)"
        fi
        ;;
    redis)
        echo
        log_info "Redis connection info:"
        echo "   Host: ${APP_NAME}-master.${NAMESPACE}.svc.cluster.local"
        echo "   Port: 6379"
        if [ "$REDIS_AUTH" = true ] && [ "$NEEDS_SECRETS" = true ]; then
            echo "   Password: (from 1Password secret)"
        fi
        ;;
    mariadb)
        echo
        log_info "MariaDB connection info:"
        echo "   Host: ${APP_NAME}.${NAMESPACE}.svc.cluster.local"
        echo "   Port: 3306"
        echo "   Database: ${MARIADB_DB}"
        echo "   Username: ${MARIADB_USER}"
        if [ "$NEEDS_SECRETS" = true ]; then
            echo "   Password: (from 1Password secret)"
        fi
        ;;
    mongodb)
        echo
        log_info "MongoDB connection info:"
        echo "   Host: ${APP_NAME}.${NAMESPACE}.svc.cluster.local"
        echo "   Port: 27017"
        echo "   Database: ${MONGODB_DB}"
        echo "   Username: ${MONGODB_USER}"
        if [ "$NEEDS_SECRETS" = true ]; then
            echo "   Password: (from 1Password secret)"
        fi
        ;;
esac

echo
log_info "For more details, see: docs/deploying-applications.md"
echo
