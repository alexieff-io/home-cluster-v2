# Local Validation

Run the same `flux-local` checks on your machine that CI runs on PRs. This catches HelmRelease templating errors, missing chart values, and Kustomization path mistakes before pushing.

## Quick start

```bash
task validate
```

That's the same invocation CI runs, just executed locally via Docker. It exits non-zero on any failure.

## What `task validate` does

It runs the [`flux-local`](https://github.com/allenporter/flux-local) tool against `kubernetes/flux/cluster`, walking the full Kustomization tree and rendering every HelmRelease through Helm. Specifically:

- Resolves all `OCIRepository` / `HelmRepository` chart references
- Performs Flux `postBuild.substituteFrom` substitution (so `${SECRET_DOMAIN}` etc. resolve)
- Renders every HelmRelease via `helm template` and validates against the chart's schema
- Verifies every `Kustomization.spec.path` points at a real directory
- Reports any failures with the offending file and line

Pinned to the same `ghcr.io/allenporter/flux-local` image tag as CI (`v8.0.1`) — see `.github/workflows/flux-local.yaml`.

## Rendering a single HelmRelease

When iterating on a specific app, render just that HelmRelease to inspect the output:

```bash
docker run --rm -u "$(id -u):$(id -g)" \
    -v "$(pwd):/workspace" -v /tmp:/tmp \
    -w /workspace -e HOME=/tmp \
    --entrypoint sh \
    ghcr.io/allenporter/flux-local:v8.0.1 -c '
        git config --global --add safe.directory /workspace &&
        flux-local build helmrelease \
            --path kubernetes/flux/cluster \
            --namespace <namespace> <release-name>
    '
```

Replace `<namespace>` and `<release-name>` (e.g., `monitoring goldilocks`). The output is the rendered Kubernetes manifests as Helm would emit them.

## Why Docker (and not the local `.venv`)

The repo carries a `.venv/` pre-built with `flux-local` installed, but its Python interpreter shebang points at the absolute path where the venv was created. If the repo was cloned to a different drive or the venv was copied between hosts (common on WSL), the `.venv/bin/python` symlink is broken and you'll see:

```
/path/to/.venv/bin/flux-local: bad interpreter: /old/path/python: no such file or directory
```

The Docker route avoids this entirely — same image as CI, no host-Python dependency.

If you want a working local install instead, rebuild the venv:

```bash
rm -rf .venv
python3 -m venv .venv
.venv/bin/pip install flux-local==8.0.1
```

Then you can run `flux-local test ...` directly without Docker.

## Gotchas

**`fatal: detected dubious ownership in repository at '/workspace'`** — git inside the container doesn't trust the bind-mounted repo by default. The `task validate` recipe handles this with `git config --global --add safe.directory /workspace`. If you craft a custom invocation, include it.

**`error: could not lock config file //.gitconfig: Permission denied`** — the container ran as a different UID than your host user, so `$HOME` isn't writable. Fix with `-u "$(id -u):$(id -g)" -e HOME=/tmp -v /tmp:/tmp`.

**`Kustomization '...' path field '...' is not a directory`** — the working directory inside the container must be the repo root for relative `path:` fields to resolve. Use `-w /workspace`.

**Cache miss on first run** — Docker pulls the ~500 MB `flux-local` image once. Subsequent runs use the local layer cache and complete in ~30 seconds.

## What CI runs that this doesn't

`task validate` runs `flux-local test`. CI additionally runs `flux-local diff` (against the default branch) to post manifest diffs as PR comments. The diff job is a presentation step — if `test` passes locally, `diff` won't fail in CI for substantive reasons.
