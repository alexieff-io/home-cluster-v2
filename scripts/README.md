# Cluster Scripts

This directory contains helper scripts for managing the Kubernetes cluster.

## Available Scripts

### new-app.sh

Interactive script for bootstrapping a new application deployment.

**Usage:**

```bash
./scripts/new-app.sh
```

**Features:**

- 🎯 Interactive prompts for all configuration options
- 📁 Automatic directory structure creation
- 📝 Generates all required YAML files:
  - Flux Kustomization (`ks.yaml`)
  - OCIRepository configuration
  - HelmRelease with best practices
  - ExternalSecret (optional)
  - Kustomization manifest
- 🔧 Configurable options:
  - External/internal ingress with automatic TLS
  - Secrets from 1Password
  - Persistent storage (PVC)
  - Custom ports and health checks
- ✅ Automatically updates namespace kustomization
- 📋 Provides next-steps checklist

**Example Session:**

```
╔═══════════════════════════════════════════════════════╗
║                                                       ║
║     New Application Deployment Generator             ║
║                                                       ║
╚═══════════════════════════════════════════════════════╝

ℹ Let's set up your new application...

? Application name (lowercase, kebab-case): myapp
? Namespace [default]: default
? Container image repository [ghcr.io/myorg/myapp]:
? Container image tag [latest]: v1.0.0
? Application port [8080]:
? Health check path [/health]:

ℹ Configuration options:

? Does this app need external (internet) access? [y/N]: y
? Does this app need secrets from 1Password? [y/N]: y
? Secret name in 1Password [myapp-secret]:
? Does this app need persistent storage? [y/N]: y
? Storage size (e.g., 10Gi) [10Gi]:
? Mount path in container [/data]:

ℹ Summary:
  App Name:      myapp
  Namespace:     default
  Image:         ghcr.io/myorg/myapp:v1.0.0
  Port:          8080
  Health Path:   /health
  Ingress:       external
  Secrets:       true
  Storage:       true

? Continue with these settings? [y/N]: y
```

**Generated Structure:**

```
kubernetes/apps/default/myapp/
├── ks.yaml                           # Flux Kustomization
└── app/
    ├── kustomization.yaml            # Kustomize resources
    ├── ocirepository.yaml            # Helm chart source
    ├── helmrelease.yaml              # Application deployment
    └── externalsecret.yaml           # Secrets (if enabled)
```

**What Gets Generated:**

1. **Flux Kustomization** - Configures Flux to watch and deploy your app
2. **OCIRepository** - References the bjw-s app-template Helm chart
3. **HelmRelease** - Application deployment with:
   - Security best practices (non-root, read-only filesystem, dropped capabilities)
   - Resource limits and requests
   - Health probes (liveness and readiness)
   - HTTPRoute for ingress (if enabled)
   - Persistent storage (if enabled)
   - Secret injection (if enabled)
4. **ExternalSecret** - 1Password integration (if enabled)
5. **Namespace files** - If deploying to a new namespace

**Best Practices Included:**

- ✅ Security hardening (non-root, dropped capabilities, read-only filesystem)
- ✅ Resource limits and requests
- ✅ Health probes for reliability
- ✅ Automatic secret reloading (Reloader)
- ✅ Proper Flux integration
- ✅ Variable substitution for domain names

**After Running:**

The script provides a checklist of next steps:
1. Review generated files
2. Create secrets in 1Password (if needed)
3. Commit and push changes
4. Apply to cluster (or wait for Flux auto-sync)
5. Verify deployment

**Customization:**

After generation, you can customize the generated YAML files:
- Adjust resource limits
- Add environment variables
- Configure multiple containers
- Add init containers
- Customize health check intervals
- Add service monitors for Prometheus

**See Also:**

- [Deploying Applications Guide](../docs/deploying-applications.md)
- [External Secrets Setup](../docs/external-secrets-setup.md)

## Future Scripts

Additional scripts that could be added:

- `scale-app.sh` - Scale application replicas
- `backup-secrets.sh` - Backup 1Password secrets
- `validate-manifests.sh` - Validate YAML files before commit
- `delete-app.sh` - Clean removal of applications
- `migrate-app.sh` - Migrate app between namespaces

## Contributing

When adding new scripts:
1. Make them executable: `chmod +x scripts/script-name.sh`
2. Add proper error handling with `set -euo pipefail`
3. Include help text and usage examples
4. Document in this README
5. Follow existing script style and patterns
