# LibreChat Deployment

LibreChat is an open-source ChatGPT clone that supports multiple AI providers (OpenAI, Anthropic, Google, etc.).

## 1Password Secret Configuration

Create an item in 1Password called `librechat` with the following fields:

### Required Secrets (generate random values)
```bash
# Generate these using: openssl rand -hex 32
LIBRECHAT_CREDS_KEY="<32-byte hex string>"
LIBRECHAT_JWT_SECRET="<32-byte hex string>"
LIBRECHAT_JWT_REFRESH_SECRET="<32-byte hex string>"
LIBRECHAT_MEILI_MASTER_KEY="<32-byte hex string>"

# Generate this using: openssl rand -hex 16
LIBRECHAT_CREDS_IV="<16-byte hex string>"
```

### Optional AI Provider API Keys
```bash
# Add your API keys here (leave empty if not using)
LIBRECHAT_OPENAI_API_KEY="sk-..."
LIBRECHAT_ANTHROPIC_API_KEY="sk-ant-..."
LIBRECHAT_GOOGLE_KEY="..."
```

## Quick Start Commands

Generate all required secrets:
```bash
echo "LIBRECHAT_CREDS_KEY=$(openssl rand -hex 32)"
echo "LIBRECHAT_CREDS_IV=$(openssl rand -hex 16)"
echo "LIBRECHAT_JWT_SECRET=$(openssl rand -hex 32)"
echo "LIBRECHAT_JWT_REFRESH_SECRET=$(openssl rand -hex 32)"
echo "LIBRECHAT_MEILI_MASTER_KEY=$(openssl rand -hex 32)"
```

## Access

After deployment, LibreChat will be available at:
- **External URL**: https://chat.k8s.alexieff.io

## Components

- **LibreChat**: 2 replicas for high availability
- **MongoDB**: 20Gi Longhorn storage for chat history and user data
- **MeiliSearch**: 10Gi Longhorn storage for fast search functionality

## Configuration

### First-time Setup
1. Navigate to https://chat.k8s.alexieff.io
2. Register the first admin account
3. After creating admin account, consider disabling registration by setting `allowRegistration: false` in helmrelease.yaml

### Adding AI Providers
Add your API keys to the 1Password `librechat` item, then Flux will automatically sync them.

### Custom API URLs

The deployment includes example custom endpoint configurations in `helmrelease.yaml`. To use custom API URLs:

1. **Edit the `configYamlContent` section** in `helmrelease.yaml`
2. **Replace the example URLs** with your actual API endpoints:
   - `baseURL: "https://your-openai-proxy.com/v1"` - Your OpenAI-compatible endpoint
   - `baseURL: "https://your-anthropic-proxy.com"` - Your Anthropic proxy
   - `baseURL: "http://ollama.local:11434/v1"` - Local LLM endpoint

3. **Remove unused endpoints** or add more as needed

Example use cases:
- **Reverse proxies** for API caching/monitoring
- **Local LLMs** via Ollama, LM Studio, or vLLM
- **Alternative providers** like OpenRouter, Together.ai
- **Self-hosted models** with OpenAI-compatible APIs

Environment variables like `${OPENAI_API_KEY}` reference secrets from the ExternalSecret.

## Resources

- CPU Request: 200m (app), 100m (mongodb), 50m (meilisearch)
- Memory Request: 512Mi (app), 256Mi (mongodb), 128Mi (meilisearch)
- Memory Limit: 1Gi (app), 512Mi (mongodb), 256Mi (meilisearch)

## Monitoring

MongoDB and MeiliSearch will use Longhorn for persistent storage with automatic backups.
