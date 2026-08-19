# home-ops: FluxCD/Kubernetes GitOps Repository

## Overview

GitOps-managed Kubernetes cluster bootstrapped with FluxCD. Apps deployed via the [bjw-s app-template](https://github.com/bjw-s-labs/helm-charts) Helm chart (OCI-based). SOPS age encryption for secrets. Rook/Ceph for storage. Envoy Gateway (Gateway API) for ingress.

## Directory Structure

```
kubernetes/
├── flux/
│   ├── flux-system/           # Generated Flux manifests (gotk-components, gotk-sync)
│   └── ks.yaml                # Root Kustomization: sources ./kubernetes/apps
├── apps/                      # All apps grouped by namespace/category
│   ├── {namespace}/
│   │   ├── kustomization.yaml # Sets namespace, includes ../../components/common, lists apps
│   │   └── {app}/
│   │       ├── ks.yaml        # Flux Kustomization for this app
│   │       └── app/
│   │           ├── kustomization.yaml
│   │           ├── helmrelease.yaml   # Required: bjw-s app-template values
│   │           ├── ocirepository.yaml # Required: OCI source for app-template chart
│   │           └── secret.yaml        # Optional: SOPS-encrypted secrets
└── components/
    └── common/                # Kustomize component: Namespace + sops-age Secret
```

## Flux Structure (3-level nesting)

1. **Root** `flux/ks.yaml`: `Kustomization cluster-apps` → sources `./kubernetes/apps`, has SOPS decryption, **patches SOPS decryption into ALL child Kustomizations**
2. **Namespace-level** `apps/{ns}/kustomization.yaml`: Sets namespace, includes `../../components/common`, lists `./{app}/ks.yaml`
3. **App-level** `apps/{ns}/{app}/ks.yaml`: Flux Kustomization pointing to `./kubernetes/apps/{ns}/{app}/app`

## Sibling Directories for Independently-Lifecycled Units

When a top-level app needs two (or more) separately-reconciled pieces that share one namespace
but have different lifecycles/health checks/dependency chains — e.g. an operator vs. the custom
resource it manages, or an app vs. a small dedicated backing service it needs (Redis/Valkey,
etc.) — put them in **sibling directories**, each with its own Flux `Kustomization`, not one
nested inside the other's `app/` directory.

The canonical example: `kubernetes/apps/rook-ceph/rook-ceph/`. A single multi-document `ks.yaml`
declares **two separate `Kustomization` objects**:

```yaml
# kubernetes/apps/rook-ceph/rook-ceph/ks.yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: rook-ceph          # the operator
spec:
  path: ./kubernetes/apps/rook-ceph/rook-ceph/app
  healthChecks: [...]       # operator Deployment + CRD
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: rook-ceph-cluster  # the CephCluster CR
spec:
  path: ./kubernetes/apps/rook-ceph/rook-ceph/cluster
  dependsOn:
    - name: rook-ceph        # cross-references the sibling by name
      namespace: rook-ceph
  healthChecks: [...]       # CephCluster + StorageClasses
```

`app/` and `cluster/` are **siblings** on disk, each a flat directory with its own
`kustomization.yaml` (plain Kustomize resource list — `helmrelease.yaml`, `ocirepository.yaml`,
etc.), cross-referenced only via `dependsOn` in the parent `ks.yaml`, never by one directory
including the other's path. Same pattern used for `kubernetes/apps/authentik/authentik/`
(`valkey/` + `app/`).

**Don't** nest a second app's manifests inside an existing `app/` directory (e.g. an app's own
Redis/Valkey release living at `app/valkey/`) — that loses independent health-gating and reads
as if it's part of the same release when it isn't. If two things genuinely deploy and reconcile
together as one unit (e.g. a CNPG `Cluster` CR living alongside the chart that uses it, per
`kubernetes/apps/misc/linkwarden/app/cluster.yaml`), bundling in the same `app/` dir is fine —
the test is whether the two pieces have their own independent lifecycle/health check worth
tracking separately, not just "is it a separate YAML file."

## Adding a New App (Required Files)

### 1. `apps/{category}/{app-name}/ks.yaml`
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app {app-name}
  namespace: &namespace {namespace}
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    - name: envoy-gateway-config
      namespace: network
    - name: rook-ceph-cluster
      namespace: rook-ceph
  interval: 1h
  path: ./kubernetes/apps/{category}/{app-name}/app
  prune: true
  retryInterval: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: *namespace
  timeout: 5m
  wait: false
```

### 2. `apps/{category}/{app-name}/app/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
  # - ./secret.yaml        # add if needed
```

### 3. `apps/{category}/{app-name}/app/ocirepository.yaml`
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: {app-name}
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 5.0.1                # app-template chart version
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

### 4. `apps/{category}/{app-name}/app/helmrelease.yaml`

Uses `chartRef` pointing to the OCIRepository. Key `values` sections:

| Section | Description |
|---------|-------------|
| `controllers.{name}.containers.app.image` | Container image: `repository` + `tag@sha256:` |
| `controllers.{name}.annotations` | `reloader.stakater.com/auto: "true"` |
| `controllers.{name}.containers.app.probes` | liveness/readiness (HTTP), startup |
| `controllers.{name}.containers.app.securityContext` | `readOnlyRootFilesystem: true`, `capabilities: { drop: ["ALL"] }` |
| `controllers.{name}.containers.app.resources` | Requests/limits |
| `defaultPodOptions.securityContext` | `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroup: 1000`, `fsGroupChangePolicy: OnRootMismatch` |
| `service.app` | Single service named `app`, controller ref, ports |
| `route.app` | Hostnames, parentRefs to `envoy-internal` or `envoy-external` |
| `persistence` | PVCs (`storageClass: "ceph-block"`, `suffix`, `accessMode: ReadWriteOnce`, `size`, `globalMounts`) and/or `emptyDir` volumes |

### 5. `apps/{category}/{app-name}/app/secret.yaml` (SOPS-encrypted, if needed)
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: {app-name}-secret
data:
  KEY: ENC[AES256_GCM,...]
```

Referenced in helmrelease via:
```yaml
envFrom:
  - secretRef:
      name: "{{ .Release.Name }}-secret"
```

### 6. Register in namespace kustomization
Add to `apps/{category}/kustomization.yaml`:
```yaml
resources:
  - ./{app-name}/ks.yaml
```

## SOPS Secrets

- **Config**: `.sops.yaml` — age key, encrypts `data`/`stringData` fields only
- **Key**: Single age key stored as `kubernetes/components/common/sops/secret.sops.yaml`
- **Injection**: `common` kustomize component creates `sops-age` Secret + Namespace in every namespace
- **Decryption**: Root Kustomization patches SOPS decryption into all child Kustomizations
- **Usage**: `sops --encrypt secret.yaml` to encrypt, `sops secret.yaml` to edit. Decryption is automatic via Flux.
- **Agent behavior**: Never run `sops`, touch age keys, or attempt encryption yourself. Write `secret.yaml` with plaintext `stringData` and explicitly warn the user it still needs to be `sops`-encrypted before committing/applying.

## Database Operators

| Operator | Namespace | CRDs | Helm Source |
|----------|-----------|------|-------------|
| CloudNativePG (postgres) | `database` | `clusters.postgresql.cnpg.io` | HelmRepository: `https://cloudnative-pg.github.io/charts`, chart: `cloudnative-pg` v0.26.0 |
| MariaDB Operator | `database` | `mariadbs.mariadb.mariadb.com`, etc. | HelmRepository: `https://helm.mariadb.com/mariadb-operator`, chart: `mariadb-operator` v25.8.4 |

Both operators are installed. Database instances are defined as custom resources alongside the app that needs them (see `apps/immich/immich/app/cluster.yaml` for an example CNPG `Cluster` resource).

CloudNativePG auto-generates connection credentials into a Secret named `<cluster-name>-app` (e.g., `immich-postgres-app`). Apps reference individual keys via `valueFrom.secretKeyRef`:
```yaml
env:
  DB_USERNAME:
    valueFrom:
      secretKeyRef:
        name: immich-postgres-app
        key: username
  DB_PASSWORD:
    valueFrom:
      secretKeyRef:
        name: immich-postgres-app
        key: password
```
The read-write service is always `<cluster-name>-rw` (e.g., `immich-postgres-rw`).

## Networking

- **Gateway API controller**: Envoy Gateway
- **Gateways** (in `network` namespace):
  - `envoy-external`: `*.external.oreillys.io`, IP `10.21.0.1`
  - `envoy-internal`: `*.internal.oreillys.io`, IP `10.21.0.2`
- **TLS**: Wildcard cert `*.oreillys.io` via cert-manager + Let's Encrypt DNS-01 (Cloudflare)
- **Routes**: Apps create `HTTPRoute` resources via `route` block in app-template values
  - Internal: `parentRefs: [{ name: envoy-internal, namespace: network, sectionName: https }]`
  - External: `parentRefs: [{ name: envoy-external, namespace: network, sectionName: https }]`

## Storage

- **Rook/Ceph** in `rook-ceph` namespace
- **StorageClasses**: `ceph-block` (RWO, default), `ceph-filesystem` (RWX)
- Apps use `storageClass: "ceph-block"` with `accessMode: ReadWriteOnce` for PVCs

## Existing Namespaces & Apps

| Namespace | Apps |
|-----------|------|
| `cert-manager` | cert-manager |
| `database` | postgres-operator, mariadb-operator |
| `download` | sabnzbd, sonarr, radarr, prowlarr, recyclarr |
| `external-secrets` | external-secrets |
| `home` | home-assistant, frigate, grocy |
| `immich` | immich |
| `kube-system` | kube-vip, kube-vip-cloud-provider, metrics-server, kured, reloader, snapshot-controller |
| `media` | jellyfin, audiobookshelf, ersatztv |
| `network` | envoy-gateway, certificates, omada-controller |
| `observability` | kube-prometheus-stack, grafana, fluent-bit, loki, smartctl-exporter, gatus |
| `rook-ceph` | rook-ceph, rook-ceph-cluster |

## Scaffolding Tool: `scripts/new-app.py`

Generates the 4 required files for a new app from Jinja2 templates:

```
scripts/new-app.py \
  --namespace <category> \
  --name <app-name> \
  --image <repository> \
  --tag <version> \
  --digest <sha256> \
  --hostname <app>.internal.oreillys.io \
  --volume config:1Gi:/config \
  --volume media:100Gi:/media \
  --volume tmpfs:emptyDir:/tmp \
  --env KEY=VALUE \
  --add-secret \
  --port 8096 \
  --probe-path /health
```

Templates live in `templates/app-template/` — edit them to adjust the output for all future apps. Run with `--dry-run` to preview, `--force` to overwrite existing files.

### Parameters

| Flag | Required | Description |
|------|----------|-------------|
| `-n`/`--namespace` | yes | Namespace/category (media, home, etc.) |
| `-a`/`--name` | yes | App name (kebab-case) |
| `-i`/`--image` | yes | Container image repository |
| `-t`/`--tag` | yes | Image version tag |
| `-d`/`--digest` | yes | SHA256 digest hex string |
| `-H`/`--hostname` | yes | Route hostname (e.g. app.internal.oreillys.io) |
| `-v`/`--volume` | no | `name:size:mountPath[:subPath]` (repeatable, `emptyDir` for tmpfs) |
| `-p`/`--port` | no | Container port (default 8080) |
| `--probe-path` | no | HTTP health check path (default `/health`, use `none` to skip) |
| `--startup-probe` | no | Add a startup probe (30 retries) |
| `-e`/`--env` | no | Extra env vars `KEY=VALUE` (repeatable) |
| `--route-type` | no | `internal` (default) or `external` |
| `--add-secret` | no | Add secret.yaml + envFrom reference |
| `--no-reloader` | no | Skip reloader annotation |
| `--chart-version` | no | app-template chart version (default 4.3.0) |
| `--memory-limit` | no | Memory limit (default 1Gi) |
| `--dry-run` | no | Print to stdout, don't write files |
| `--force` | no | Overwrite existing files |

## Multi-Controller Apps (immich pattern)

When an app needs multiple processes (e.g., server + ML + cache), define them as separate controllers in the same HelmRelease. Each controller becomes its own Deployment with its own service:

```yaml
controllers:
  server:
    containers:
      app:
        image: ...
        env:
          # reference other services via {{ .Release.Name }}-<service-key>
          REDIS_HOSTNAME: "{{ .Release.Name }}-valkey"
          ML_URL: "http://{{ .Release.Name }}-ml:3003"
  ml:
    containers:
      app:
        image: ...
  valkey:
    pod:
      securityContext:     # override defaultPodOptions if needed (e.g., different UID)
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
    containers:
      app:
        image: ...

service:
  app:        # creates <ReleaseName>-app service
    controller: server
    ports:
      http:
        port: 2283
  ml:         # creates <ReleaseName>-ml service
    controller: ml
    ports:
      http:
        port: 3003
  valkey:     # creates <ReleaseName>-valkey service
    controller: valkey
    ports:
      tcp:
        port: 6379
```

Persistence can target specific controllers via `advancedMounts`:
```yaml
persistence:
  cache:
    suffix: cache
    storageClass: "ceph-block"
    accessMode: ReadWriteOnce
    size: "10Gi"
    advancedMounts:
      ml:                           # only mounts on the 'ml' controller
        app:
          - path: /cache
  tmp:
    type: emptyDir
    advancedMounts:
      server:                       # mounts /tmp on both
        app:
          - path: /tmp
      ml:
        app:
          - path: /tmp
```

## Conventions

- **Naming**: kebab-case for apps, `{app}-secret` for secrets, `{suffix}` for PVCs
- **YAML anchors**: `&app`/`&namespace` for DRY name/namespace references
- **Images**: `tag@sha256:` digest pinning
  - Find digests with `skopeo inspect --raw docker://ghcr.io/org/repo:tag | python3 -c "import sys,json; i=json.load(sys.stdin); [print(m['digest']) for m in i['manifests'] if m.get('platform',{}).get('architecture')=='amd64']"`
- **Chart version**: `5.0.1` for app-template
- **User/Group**: `1000:1000` throughout
- **Reloader**: `reloader.stakater.com/auto: "true"` annotation on controllers for auto-restart on secret/config changes
- **Probes**: YAML anchors (`&probes`) shared between liveness and readiness
- **Service name**: Always `app` for the primary service
- **Comments**: minimal - only the non-obvious "why" (a hidden constraint, a gotcha). No narrative/history of the change or the incident that prompted it; that belongs in the commit message, not the file.
