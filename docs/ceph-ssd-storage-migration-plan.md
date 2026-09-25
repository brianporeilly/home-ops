# Ceph HDD -> SSD Storage Migration Plan

Goal: move latency-sensitive PVCs off `ceph-block` (the default pool, backed by
3 HDDs across `wk-drotte`/`wk-eata`/`wk-roche` — two of which are old WD Green
desktop drives averaging ~176-178ms apply latency) onto `ceph-block-ssd`
(3 SSDs, ~2-4ms apply latency, 871GiB free as of 2026-09-25).

`ceph-blockpool` (the pool behind `ceph-block`) is size=3 replicated across
exactly 3 HDD hosts, so CRUSH has zero placement choice today — every single
write to *any* image in that pool is already gated by both bad WD Greens. This
means client-observed write latency (200-700ms, measured via the
`ceph_rbd_*` per-image stats - see the "Ceph RBD IOStat" Grafana dashboard,
Storage folder) is much worse than the raw ~178ms OSD apply-latency number
alone suggests, for every app on that pool, not just the busy ones.

Candidates identified so far (via the dashboard, 2026-09-25):

| PVC | IOPS | Avg Write Latency | Status |
|---|---|---|---|
| `akvorado-clickhouse-storage-chi-...` | 48.2 | 435ms | Planned - see below, not yet migrated (single instance, holds real data) |
| `prometheus-...-db-...-0` | 4.1 | 483ms | Planned - PR pending |
| `prometheus-...-db-...-1` | 1.9 | 206ms | Planned - PR pending |
| `alertmanager-...-db-...-0` | 0.02 | 686ms | Planned - PR pending |
| `alertmanager-...-db-...-1` | 0.02 | 174ms | Planned - PR pending |
| `alertmanager-...-db-...-2` | 0.02 | 101ms | Planned - PR pending |
| `gatus-sidecar` | 0.83 | 205ms | Identified, not yet scheduled |

Use the dashboard periodically to look for more candidates as usage patterns
change - the `$namespace`/`$storageclass` filters make it easy to check "is
anything still hot on ceph-block" without re-deriving the PromQL each time.

## Prometheus + Alertmanager (safe, HA-tolerant)

Both are StatefulSets designed to tolerate a single replica losing its local
disk state: Alertmanager replicas gossip silences/notification log between
peers, and Prometheus's 2 replicas independently scrape the same targets.
Losing one replica's local data is an expected, self-healing event, not an
outage - this is *why* these are the safe ones to do first, ahead of
ClickHouse.

`storageClassName` is immutable on an existing PVC, and the field is also
immutable on an existing `StatefulSet` object once created - the
`kube-prometheus-stack` values change alone (`ceph-block` -> `ceph-block-ssd`
in `kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml`)
does not retroactively touch already-bound PVCs. The prometheus-operator
handles the immutable-StatefulSet-field problem itself (deletes and recreates
the StatefulSet object when it detects a volumeClaimTemplate change), but the
**existing PVCs and pods are untouched** until you delete them - that's the
manual, one-at-a-time step below.

**Procedure** (repeat per StatefulSet, one ordinal at a time - never delete
two replicas' PVCs concurrently, or you lose HA during the migration):

1. Merge the storageClassName change and let Flux reconcile
   `kube-prometheus-stack`.
2. Confirm the operator actually recreated the StatefulSet with the new class:
   `kubectl get statefulset -n observability prometheus-kube-prometheus-stack -o jsonpath='{.spec.volumeClaimTemplates[0].spec.storageClassName}'`
   (same pattern for `alertmanager-kube-prometheus-stack`) - should read
   `ceph-block-ssd` before proceeding.
3. For each ordinal `N` (start with `N=1`, the non-leader/non-primary
   replica where possible, so quorum/scraping never drops to zero):
   - `kubectl delete pod -n observability <statefulset>-N`
   - `kubectl delete pvc -n observability <pvc-name>-N` (the old PVC has to
     go too - the StatefulSet won't provision a new one under an existing
     PVC name)
   - Wait for the pod to come back `Running`/`Ready` on the new PVC
     (`kubectl get pvc -n observability <pvc-name>-N -o jsonpath='{.spec.storageClassName}'`
     should now read `ceph-block-ssd`) and for Alertmanager to show the
     replica rejoined the cluster / Prometheus to show it scraping again,
     before moving to the next ordinal.
4. Repeat for the remaining ordinal(s).

Alertmanager has 3 replicas (do `1`, `2`, then `0`); Prometheus has 2 (do `1`,
then `0`).

## Akvorado ClickHouse (data-preserving migration needed)

Single instance (`akvorado-clickhouse-storage-chi-akvorado-clickhouse-akvorado-0-0-0`,
50Gi) - no replica, and it's the actual store of collected NetFlow history.
The delete-PVC approach above would permanently lose all historical flow data
instead of self-healing. Losing that data is acceptable if it comes to it, but
a data-preserving migration is preferred. Options, not yet decided:

1. **CSI VolumeSnapshot -> restore into `ceph-block-ssd`** (try this first):
   this cluster already snapshots PVCs routinely for backups (confirmed
   2026-09-25 - `kubectl get volumesnapshot -A` shows active hourly-ish
   snapshots for several apps' config PVCs), all via the single
   `csi-ceph-blockpool` VolumeSnapshotClass (driver `rook-ceph.rbd.csi.ceph.com`
   - the same driver that backs `ceph-block-ssd` too, just a different pool).
   Restoring a snapshot into a PVC with a *different* storageClassName than
   the source, but the *same* provisioner, is generally supported by RBD's
   CSI driver. Not yet proven cross-pool on this exact cluster/version, so
   the plan is: snapshot the ClickHouse PVC, create a new `ceph-block-ssd`
   PVC with `dataSource: {kind: VolumeSnapshot, name: <snap>}`, and confirm
   it actually populates with the real data before touching the live CHI
   resource. If this works, no rsync job or app downtime needed beyond a
   brief ClickHouse restart to repoint at the new PVC.
2. **rsync via a temporary job** (fallback if (1) doesn't pan out): mount
   both the existing `ceph-block` PVC and a newly-created `ceph-block-ssd`
   PVC into one throwaway pod, stop (or accept a brief pause of) the
   ClickHouse pod, `rsync -a` the ClickHouse data directory across, then
   repoint the CHI resource at the new PVC and restart. Needs the CHI's
   exact data path confirmed first.
3. **Accept data loss**: same delete-PVC-and-let-it-recreate approach as
   Prometheus/Alertmanager, just with the explicit understanding that
   ClickHouse's flow history starts over from empty. Simplest fallback if
   neither migration path above is worth the effort.

Next step: test (1) - snapshot the ClickHouse PVC and try restoring into a
`ceph-block-ssd` PVC in a scratch namespace/name first, to confirm cross-pool
restore actually works on this cluster before doing it against the real CHI.
