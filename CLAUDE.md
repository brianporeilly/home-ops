# Repo conventions

## Sibling directories for independently-lifecycled units, not nested apps

When a top-level app needs two (or more) separately-reconciled pieces that share one namespace
but have different lifecycles/health checks/dependency chains — e.g. an operator vs. the custom
resource it manages, or an app vs. a small dedicated backing service it needs (Redis/Valkey,
etc.) — put them in **sibling directories**, each with its own Flux `Kustomization`, not one
nested inside the other's `app/` directory.

The canonical example already in this repo: `kubernetes/apps/rook-ceph/rook-ceph/`. A single
multi-document `ks.yaml` declares **two separate `Kustomization` objects**:

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
including the other's path.

**Don't** nest a second app's manifests inside an existing `app/` directory (e.g. an app's own
Redis/Valkey release living at `app/valkey/`) — that loses independent health-gating and reads
as if it's part of the same release when it isn't. If two things genuinely deploy and reconcile
together as one unit (e.g. a CNPG `Cluster` CR living alongside the chart that uses it, per
`kubernetes/apps/misc/linkwarden/app/cluster.yaml`), bundling in the same `app/` dir is fine —
the test is whether the two pieces have their own independent lifecycle/health check worth
tracking separately, not just "is it a separate YAML file."
