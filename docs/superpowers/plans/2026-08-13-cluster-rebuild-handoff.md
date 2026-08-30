# Cluster Rebuild Handoff Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained, sanitized, checksum-protected package that an independent agent can use to recreate this cluster from a fresh `onedr0p/cluster-template` repository and redeploy all current GitOps-managed applications with empty state.

**Architecture:** Treat the current Git repository as the desired-state source and the live cluster as metadata-only corroboration. Copy only safe application/component manifests, explicitly map template ownership and dependencies, provide a prefilled non-secret target configuration, and drive the rebuild through gated runbooks and standalone session prompts. Finish by scanning for forbidden material, checking inventory parity, generating checksums, and creating a reproducible tar archive.

**Tech Stack:** YAML, Markdown, Talos Linux, Kubernetes, Flux CD, SOPS/Age, External Secrets, 1Password, `kubectl`, SHA-256, gzip/tar

## Global Constraints

- Target template repository: `https://github.com/onedr0p/cluster-template`.
- Target template commit: `bb09348610aa5bee9505230b99c21c08db15bf6d`.
- Create a fresh target repository; do not transform this repository in place.
- Reuse `node1`–`node4`, node IPs `10.69.0.10`–`10.69.0.13`, API VIP `10.69.0.25`, pod CIDR `10.42.0.0/16`, service CIDR `10.43.0.0/16`, and gateway IPs `10.69.0.26`–`10.69.0.28`.
- Preserve every application represented by `kubernetes/apps/*/*/ks.yaml`.
- Migrate configuration only; all persistent applications start with empty state.
- Never include kubeconfigs, Talos secrets, Age private keys, deploy private keys, Cloudflare credentials, token files, etcd snapshots, plaintext Kubernetes Secret values, or decrypted SOPS content.
- Package generation must not mutate the live cluster or current GitOps desired state.
- No destructive cluster action is part of package generation.

---

### Task 1: Source and Live Inventories

**Files:**
- Create: `handoff/cluster-rebuild/inventories/source-cluster.yaml`
- Create: `handoff/cluster-rebuild/inventories/applications.yaml`
- Create: `handoff/cluster-rebuild/inventories/dependencies.yaml`
- Create: `handoff/cluster-rebuild/inventories/secrets-and-prerequisites.yaml`
- Create: `handoff/cluster-rebuild/inventories/live-snapshot/nodes.yaml`
- Create: `handoff/cluster-rebuild/inventories/live-snapshot/namespaces.yaml`
- Create: `handoff/cluster-rebuild/inventories/live-snapshot/flux-kustomizations.yaml`
- Create: `handoff/cluster-rebuild/inventories/live-snapshot/helmreleases.yaml`
- Create: `handoff/cluster-rebuild/inventories/live-snapshot/workloads.yaml`
- Create: `handoff/cluster-rebuild/inventories/live-snapshot/networking.yaml`
- Create: `handoff/cluster-rebuild/inventories/live-snapshot/storage.yaml`

**Interfaces:**
- Consumes: current repository manifests and metadata-only `kubectl get` output.
- Produces: authoritative application IDs in the form `<source-folder>/<application>`; dependency edges keyed by those IDs; sanitized live metadata used by mappings and runbooks.

- [ ] **Step 1: Enumerate every GitOps application**

Collect every path matching `kubernetes/apps/*/*/ks.yaml`. Record exactly one `applications.yaml` entry per path with source folder, effective namespace, app name, source path, persistence mode, routes, secret dependencies, and status `migrate`.

- [ ] **Step 2: Extract dependency references**

For every app, record Flux `dependsOn`, `sourceRef`, `valuesFrom`, `substituteFrom`, ExternalSecret store/item/field references, and Gateway parent references. Use explicit empty lists when a reference class is absent.

- [ ] **Step 3: Record the approved topology**

Populate `source-cluster.yaml` from `talos/talconfig.yaml`, `architecture.md`, and current node metadata. Include node names, addresses, MACs, install disk, architecture, API VIP, gateway IPs, CIDRs, current platform stack, and pinned target template.

- [ ] **Step 4: Capture sanitized live metadata**

Run metadata-only commands equivalent to:

```bash
kubectl get nodes -o yaml
kubectl get namespaces -o yaml
kubectl get kustomizations --all-namespaces -o yaml
kubectl get helmreleases --all-namespaces -o yaml
kubectl get deployments,statefulsets,daemonsets --all-namespaces -o yaml
kubectl get services,gateways,httproutes --all-namespaces -o yaml
kubectl get storageclasses,persistentvolumeclaims --all-namespaces -o yaml
```

Reduce each result to identity, namespace, ownership labels, readiness/status summary, images where relevant, and non-secret topology. Do not copy `managedFields`, Secret resources, environment values, or controller payloads.

- [ ] **Step 5: Verify inventory parity**

Run a count/set comparison between `kubernetes/apps/*/*/ks.yaml` and `applications.yaml`. Expected: equal counts, no missing IDs, no duplicate IDs.

- [ ] **Step 6: Commit inventory artifacts**

```bash
git add handoff/cluster-rebuild/inventories
git commit -m "docs: inventory cluster rebuild inputs"
```

### Task 2: Sanitized Desired-State Payload

**Files:**
- Create: `handoff/cluster-rebuild/payload/apps/**`
- Create: `handoff/cluster-rebuild/payload/components/**`
- Create: `handoff/cluster-rebuild/payload/cluster.toml.example`

**Interfaces:**
- Consumes: source application/component manifests and `source-cluster.yaml`.
- Produces: self-contained safe migration payload; target configuration keys consumed by runbooks and prompts.

- [ ] **Step 1: Copy application desired state**

Copy `kubernetes/apps/` into `payload/apps/` while preserving namespace, application, `app/`, and `ks.yaml` structure. Exclude generated output, caches, runtime data, and any file containing plaintext Secret data.

- [ ] **Step 2: Copy reusable components**

Copy `kubernetes/components/` into `payload/components/` only when the component is referenced by a migrated application and is not wholly owned by the pinned template. Preserve encrypted SOPS manifests only as ciphertext and never copy an Age private key.

- [ ] **Step 3: Sanitize payload files**

Reject these source paths and classes unconditionally:

```text
kubeconfig
age.key
github-deploy.key
github-push-token.txt
cloudflare-tunnel.json
etcd-*.db
talos/talsecret.sops.yaml
talos/clusterconfig/**
.private/**
```

Inspect Kubernetes `Secret` manifests and allow only SOPS-encrypted ciphertext or non-sensitive public data. Replace no value with invented content; exclude unsafe files and record the reconstruction prerequisite in `secrets-and-prerequisites.yaml`.

- [ ] **Step 4: Create the target cluster configuration example**

Write valid TOML using the pinned template schema. Prefill the approved node/network values, MAC addresses, install disks, Talos schematic, Cilium mode when known, and gateway IPs. Use explicit sentinel strings only for values the handoff agent must obtain, such as repository URL and domain; leave secret token values empty as required by the template schema.

- [ ] **Step 5: Parse payload configuration**

Verify every YAML payload document parses and `cluster.toml.example` parses as TOML. Encrypted scalar content must remain byte-for-byte encrypted.

- [ ] **Step 6: Commit payload**

```bash
git add handoff/cluster-rebuild/payload handoff/cluster-rebuild/inventories/secrets-and-prerequisites.yaml
git commit -m "docs: add sanitized cluster migration payload"
```

### Task 3: Template Ownership and Source Mapping

**Files:**
- Create: `handoff/cluster-rebuild/mappings/template-overlap.yaml`
- Create: `handoff/cluster-rebuild/mappings/source-to-target.yaml`

**Interfaces:**
- Consumes: `applications.yaml`, `dependencies.yaml`, payload paths, and pinned template layout.
- Produces: one ownership record for every overlapping platform component and one target record for every application ID.

- [ ] **Step 1: Map template-owned components**

Create records for Talos generation, Cilium, CoreDNS, Spegel, cert-manager, Flux, Envoy Gateway, external DNS/tunnel, Reloader, and the template's example app. Mark each as `template`, `compare-and-overlay`, `replace-template-example`, or `migrate`, with source paths and required differences.

- [ ] **Step 2: Assign deployment waves**

Assign every application to an integer wave based on its operators, secrets, storage, and explicit Flux dependencies. Cross-namespace dependencies must name the effective namespace.

- [ ] **Step 3: Map source paths to generated target paths**

For every application ID, record source payload path, intended target path, owner, wave, adaptations, fresh-state outcome, and verification targets. No application may have more than one target record.

- [ ] **Step 4: Validate mapping completeness**

Compare the application ID sets in `applications.yaml` and `source-to-target.yaml`. Expected: exact set equality and no duplicate IDs.

- [ ] **Step 5: Commit mappings**

```bash
git add handoff/cluster-rebuild/mappings
git commit -m "docs: map cluster template migration ownership"
```

### Task 4: Gated Migration Runbooks

**Files:**
- Create: `handoff/cluster-rebuild/START-HERE.md`
- Create: `handoff/cluster-rebuild/runbooks/00-preflight.md`
- Create: `handoff/cluster-rebuild/runbooks/01-generate-target.md`
- Create: `handoff/cluster-rebuild/runbooks/02-port-platform.md`
- Create: `handoff/cluster-rebuild/runbooks/03-port-apps.md`
- Create: `handoff/cluster-rebuild/runbooks/04-recreate-secrets.md`
- Create: `handoff/cluster-rebuild/runbooks/05-cutover-bootstrap.md`
- Create: `handoff/cluster-rebuild/runbooks/06-verify.md`

**Interfaces:**
- Consumes: inventories, mappings, target template README/config schema, and package security constraints.
- Produces: ordered human/agent workflow with explicit evidence and stop conditions.

- [ ] **Step 1: Write the package entry point**

State scope, configuration-only data loss boundary, template pin, topology, reading order, package integrity command, forbidden material, and the rule that cutover requires explicit user authorization in the cutover session.

- [ ] **Step 2: Write preflight and target-generation runbooks**

Include exact checks for hardware facts, target repository access, template revision checkout, `mise`/`just` setup, `cluster.toml` completion, generated repository validation, Flux repository credentials, and inventory parity. Block on any failed prerequisite.

- [ ] **Step 3: Write platform and application port runbooks**

Use the ownership mapping and waves. Require the implementation agent to compare generated template resources before carrying deviations, remove the template example app, preserve one ownership path per component, adapt manifests to target conventions, and validate after each wave.

- [ ] **Step 4: Write secrets runbook**

Require a new Age key, SOPS re-encryption, safe 1Password/External Secrets reconnection, Cloudflare/DNS prerequisites, and readiness evidence that never prints secret values. Explicitly prohibit copying source private keys into the target repository.

- [ ] **Step 5: Write cutover and verification runbooks**

Make destructive commands conditional on an explicit same-session authorization. State that no application data can be recovered from this package. Verify Talos health, Kubernetes readiness, Cilium, Flux, storage provisioning, certificates, DNS, gateways/routes, application rollout, and exact inventory parity.

- [ ] **Step 6: Scan runbooks for ambiguous instructions**

Reject `TBD`, `TODO`, guessed commands, implicit prerequisites, or any instruction to bypass a failed gate.

- [ ] **Step 7: Commit runbooks**

```bash
git add handoff/cluster-rebuild/START-HERE.md handoff/cluster-rebuild/runbooks
git commit -m "docs: add gated cluster rebuild runbooks"
```

### Task 5: Independent Session Prompts

**Files:**
- Create: `handoff/cluster-rebuild/prompts/01-generate-target.md`
- Create: `handoff/cluster-rebuild/prompts/02-port-platform.md`
- Create: `handoff/cluster-rebuild/prompts/03-port-apps.md`
- Create: `handoff/cluster-rebuild/prompts/04-recreate-secrets.md`
- Create: `handoff/cluster-rebuild/prompts/05-cutover-bootstrap.md`
- Create: `handoff/cluster-rebuild/prompts/06-post-bootstrap-verify.md`

**Interfaces:**
- Consumes: corresponding runbook, named predecessor artifact, package-relative paths.
- Produces: standalone prompt text that can be pasted into a fresh agent session without prior conversation.

- [ ] **Step 1: Define the prompt contract**

Every prompt must state the target repository working directory expectation, package path, required predecessor outputs, files it may change, deliverable, stop conditions, security boundary, and exact verification commands.

- [ ] **Step 2: Write non-destructive preparation prompts**

Create target-generation, platform-port, application-port, and secrets prompts. Require each session to write a completion artifact in the target repository before a later session proceeds.

- [ ] **Step 3: Write cutover prompt**

Require explicit user authorization after presenting the exact nodes and data-loss statement. The prompt must stop without authorization and must not infer approval from the existence of the package.

- [ ] **Step 4: Write final verification prompt**

Require source-to-live inventory comparison, health evidence, application reachability checks, and a report of all deviations. Do not permit declaring success from Flux reconciliation alone.

- [ ] **Step 5: Verify prompt independence**

Read each prompt as if no chat history exists. Confirm every input is either package-relative, target-repository-relative, generated by the preceding prompt, or explicitly requested from the user.

- [ ] **Step 6: Commit prompts**

```bash
git add handoff/cluster-rebuild/prompts
git commit -m "docs: add standalone cluster migration prompts"
```

### Task 6: Package Manifest, Security Scan, and Archive

**Files:**
- Create: `handoff/cluster-rebuild/manifest.yaml`
- Create: `handoff/cluster-rebuild/checksums.sha256`
- Create: `handoff/cluster-rebuild.tar.gz`
- Create: `handoff/cluster-rebuild.tar.gz.sha256`

**Interfaces:**
- Consumes: complete `handoff/cluster-rebuild/` tree.
- Produces: versioned artifact manifest, per-file integrity list, deterministic archive, and archive checksum.

- [ ] **Step 1: Write package manifest**

Record package version `1`, UTC generation timestamp, source revision, target template pin, topology summary, application/payload counts, included sections, exclusions, state-migration policy, and completed validation checks.

- [ ] **Step 2: Run forbidden-path scan**

Fail if any package path matches private keys, kubeconfigs, credential JSON, token files, etcd snapshots, Talos secrets, generated Talos clusterconfig, `.private`, or cache directories.

- [ ] **Step 3: Run content scan**

Inspect payload and inventory content for PEM private-key headers, Age private-key headers, kubeconfig authentication material, Cloudflare tunnel credential fields, unencrypted `Secret.data`/`Secret.stringData`, and obvious token assignments. Review every match; no unresolved match is allowed.

- [ ] **Step 4: Verify YAML/TOML and set parity**

Parse all YAML and TOML files. Re-run application inventory and source-to-target mapping set comparisons. Expected: no parse errors, exact application set equality, and no duplicate IDs.

- [ ] **Step 5: Generate per-file checksums**

Generate sorted SHA-256 entries for every package file except `checksums.sha256`, then write `checksums.sha256`. Verify every entry before archiving.

- [ ] **Step 6: Create and verify archive**

Create `handoff/cluster-rebuild.tar.gz` with `cluster-rebuild/` as its root. Write its SHA-256 to `handoff/cluster-rebuild.tar.gz.sha256`, extract it into a temporary directory, verify the archive checksum, and verify the internal checksum list from the extracted tree.

- [ ] **Step 7: Smoke-test the handoff**

Follow `START-HERE.md` through the non-destructive preflight boundary using only files from the extracted archive. Confirm that the next required action is target repository generation and that no live mutation command has run.

- [ ] **Step 8: Commit final package metadata and archive**

```bash
git add handoff/cluster-rebuild handoff/cluster-rebuild.tar.gz handoff/cluster-rebuild.tar.gz.sha256
git commit -m "docs: package cluster rebuild handoff"
```

## Final Review

- [ ] Confirm every requirement in `docs/superpowers/specs/2026-08-13-cluster-rebuild-handoff-design.md` maps to a completed task above.
- [ ] Confirm the working package is non-destructive and contains no persistent data.
- [ ] Confirm archive and internal SHA-256 verification both pass from a clean extraction.
- [ ] Confirm all 50 currently discovered GitOps application paths are inventoried and mapped; if the source count changes during implementation, use the fresh exact count instead of forcing 50.
- [ ] Report the exact package paths, checksums, source revision, target template pin, validation commands, and external prerequisites.
