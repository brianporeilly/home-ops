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

## Akvorado ClickHouse - Done (2026-09-25)

Single instance (`akvorado-clickhouse-storage-chi-akvorado-clickhouse-akvorado-0-0-0`,
50Gi) - no replica, and it's the actual store of collected NetFlow history.
The delete-PVC approach above would permanently lose all historical flow data
instead of self-healing, so a data-preserving migration was used instead.

**Result:** migrated successfully to `ceph-block-ssd`, with a small, bounded,
understood loss - not a clean zero-loss migration. `flows` table went from
29,484,787 to 28,854,787 rows (-630,000, ~2.1%). ClickHouse itself came up
healthy with no structural damage; Akvorado's outlet reconnected within
seconds of the pod coming back and drained its Kafka backlog to a lag of 2
messages almost immediately - ongoing ingestion was never at risk, this is
purely a one-time gap in already-recorded history.

**Root cause of the gap - order of operations matters:** the snapshot was
taken *before* stopping the CHI, and a few minutes elapsed (spent validating
the snapshot in a scratch PVC first) before `spec.stop` actually paused
ingestion. ClickHouse kept ingesting live flows during that window; those
Kafka offsets were already committed against the (since-deleted) old
instance, so they don't replay. **For any future live-snapshot migration on
a single-instance stateful app: stop the workload *first*, then snapshot the
now-idle volume.** That gets a perfectly quiesced, zero-loss snapshot instead
of a crash-consistent one - the validate-the-snapshot-before-cutover step is
still worth doing, just do it after stopping, not before.

A crash-consistent snapshot (the order actually used here) also produced 89
detached "broken part" errors on ClickHouse startup, spread thinly across
`akvorado.flows`/rollups (6 each) and ClickHouse's own internal system
tables (asynchronous_insert_log, text_log, etc.) - this is normal MergeTree
self-healing for parts caught mid-write, not corruption, and resolved itself
automatically without intervention. Quiescing first (see above) would have
avoided this too.

**Procedure used** (mirrors the plan drafted before execution):

1. Confirmed the cross-pool restore mechanism separately first (see the
   `thelounge` scratch-PVC test earlier in this doc) - CSI VolumeSnapshot
   restore across storage classes genuinely works on this cluster via the
   same driver (`rook-ceph.rbd.csi.ceph.com`).
2. Took a fresh `VolumeSnapshot` of the live ClickHouse PVC
   (`akvorado-clickhouse-pre-ssd-migration`, class `csi-ceph-blockpool`) -
   ready in ~9s. **This is the step that should have come after stopping the
   CHI, not before** (see the gap explanation above).
3. Restored that snapshot into a scratch `ceph-block-ssd` PVC in the
   `observability` namespace and mounted it in a throwaway pod - confirmed
   the full 19.2GB ClickHouse `store`/`metadata` directory came across
   intact before touching the live resource. Deleted the scratch PVC/pod
   after verifying.
4. Paused ClickHouse cleanly via the CHI's built-in stop field:
   `kubectl patch chi -n observability akvorado-clickhouse --type merge -p '{"spec":{"stop":"yes"}}'`
   - this tells the Altinity operator to scale the StatefulSet to 0 while
   explicitly keeping the PVC. Confirmed the pod terminated and the
   StatefulSet's replica count dropped to 0 before proceeding.
5. Deleted the old `ceph-block` PVC (data already safe in the verified
   snapshot), then immediately recreated a PVC with the **exact same name**
   (`akvorado-clickhouse-storage-chi-akvorado-clickhouse-akvorado-0-0-0`),
   `storageClassName: ceph-block-ssd`, `dataSource` pointing at the snapshot.
   This is the key trick for a CHI/StatefulSet-managed volume: since the
   operator generates a deterministic PVC name
   (`<dataVolumeClaimTemplate>-<statefulset>-<ordinal>`), you don't need to
   "repoint" anything - just make sure a PVC with that exact name exists,
   already correctly sourced, before the pod comes back.
6. Un-paused via `spec.stop: "no"`. Pod came back healthy
   (`1/1 Running`, readiness green) within ~3 minutes - most of that was
   ClickHouse re-scanning/reattaching the 50GB of MergeTree parts on
   startup, including detaching the 89 broken ones from the crash-consistent
   snapshot (see above).
7. Verified via `SELECT sum(rows) FROM system.parts WHERE active AND
   database='akvorado' GROUP BY table` - all 4 flow tables present and
   populated (see the row-count comparison above), confirmed Akvorado's
   outlet reconnected and drained its Kafka backlog immediately.
8. Also updated the git-managed `ClickHouseInstallation`
   (`storageClassName: ceph-block-ssd` in
   `kubernetes/apps/observability/akvorado/app/clickhouse.yaml`) so a
   from-scratch disaster-recovery rebuild would match reality - this had no
   live effect on its own (same immutable-field behavior as Prometheus, the
   operator doesn't retroactively touch an already-bound PVC), it's purely
   for consistency between git and the live cluster.

The migration snapshot (`akvorado-clickhouse-pre-ssd-migration`) is being
kept around temporarily as an extra rollback point rather than deleted
immediately after cutover - safe to remove once the SSD-backed instance has
been running cleanly for a while.
