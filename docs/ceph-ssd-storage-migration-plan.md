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
| `akvorado-clickhouse-storage-chi-...` | 48.2 | 435ms | Migration path confirmed working (snapshot restore, see below) - not yet executed against the real instance |
| `prometheus-...-db-...-0` | 4.1 | 483ms | **Done (2026-09-25)** - migrated via #1058 |
| `prometheus-...-db-...-1` | 1.9 | 206ms | **Done (2026-09-25)** - migrated via #1058 |
| `alertmanager-...-db-...-0` | 0.02 | 686ms | **Done (2026-09-25)** - migrated via #1058 |
| `alertmanager-...-db-...-1` | 0.02 | 174ms | **Done (2026-09-25)** - migrated via #1058 |
| `alertmanager-...-db-...-2` | 0.02 | 101ms | **Done (2026-09-25)** - migrated via #1058 |
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

**Executed 2026-09-25 - done, all 5 PVCs on `ceph-block-ssd`, no fallout.**
Confirmed cluster status `ready`/3 peers on Alertmanager and active scraping
(120 targets) on Prometheus after each ordinal, before moving to the next.

**Gotcha hit during execution:** deleting the pod and PVC together in one
shot doesn't reliably avoid a race - the StatefulSet controller often
recreates the pod fast enough that it remounts the *old* PVC (still present,
pending its `pvc-protection` finalizer) before the delete actually finalizes.
Symptom: the new pod comes back `Running` almost immediately, but
`kubectl get pvc` still shows the old `storageClassName` and the PVC sits in
`Terminating`. Fix is simple - just delete the pod a second time; once
nothing is using the PVC, the finalizer clears, the PVC is actually removed,
and *that* triggers the StatefulSet to provision a real new PVC from the
updated template. Always re-check `storageClassName` after the pod comes
back, don't assume the first recreation used the new class.

## Akvorado ClickHouse (data-preserving migration needed)

Single instance (`akvorado-clickhouse-storage-chi-akvorado-clickhouse-akvorado-0-0-0`,
50Gi) - no replica, and it's the actual store of collected NetFlow history.
The delete-PVC approach above would permanently lose all historical flow data
instead of self-healing. Losing that data is acceptable if it comes to it, but
a data-preserving migration is preferred. Options, not yet decided:

1. **CSI VolumeSnapshot -> restore into `ceph-block-ssd`** (confirmed working
   2026-09-25): tested by restoring an existing routine snapshot
   (`thelounge-20260925064200-snap`, source pool `ceph-blockpool`/HDD, class
   `csi-ceph-blockpool`) into a scratch PVC on `ceph-block-ssd` in the `misc`
   namespace. Bound in ~7s; mounted it in a throwaway pod and confirmed the
   real files came across intact (`thelounge/config.js`, `vapid.json`, with
   their original August timestamps, not empty/corrupted). Cross-pool restore
   through the same CSI driver (`rook-ceph.rbd.csi.ceph.com`) genuinely works
   on this cluster/version - no rsync job needed. Scratch PVC + pod deleted
   after verifying; underlying RBD image was reclaimed automatically
   (`reclaimPolicy: Delete` on `ceph-block-ssd`).

   **ClickHouse procedure** (not yet executed):
   - Take (or reuse the next scheduled) snapshot of
     `akvorado-clickhouse-storage-chi-akvorado-clickhouse-akvorado-0-0-0`.
   - Create a new PVC on `ceph-block-ssd` with `dataSource: {kind:
     VolumeSnapshot, name: <snap>}` (same namespace, `observability`).
   - Scale the ClickHouse StatefulSet/pod to 0 (brief downtime - Akvorado's
     outlet will queue/retry rather than drop flows during this window, but
     confirm that assumption before relying on it).
   - Repoint the `CephInstallation`/CHI resource's `volumeClaimTemplate` (or
     swap which PVC it binds, depending on how Altinity's operator manages
     this) at the new PVC name, or delete the old PVC and let the CHI
     recreate against the new one if the operator doesn't support a live
     swap.
   - Scale back up, confirm ClickHouse comes up healthy and query history
     is intact (`SELECT count() FROM flows` or similar, compare against a
     pre-migration count taken before scaling down).
   - Delete the old `ceph-block` PVC once confirmed good.
2. **rsync via a temporary job** (fallback, not needed given (1) works):
   mount both the existing `ceph-block` PVC and a newly-created
   `ceph-block-ssd` PVC into one throwaway pod and `rsync -a` the data
   across instead of using a snapshot restore.
3. **Accept data loss**: same delete-PVC-and-let-it-recreate approach as
   Prometheus/Alertmanager. Not needed now that (1) is confirmed working,
   kept here only as a last resort.

Next step: work out the exact Altinity ClickHouse-operator mechanics for
repointing an existing `CHI`'s volume at a different PVC (or whether it's
simpler to delete the old PVC first and let the CHI reprovision against the
new one directly), then execute against the real instance.
