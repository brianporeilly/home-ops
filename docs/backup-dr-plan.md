# Backup & Disaster Recovery Plan (ADR)

Status: **Partially implemented** (updated 2026-08-15). Companion to `disk-hardware-plan.md`,
`node-inventory.md`, `migration-inventory.md`. **Done:** dead-man's switch (§7), Ceph RGW S3
target (§3), CNPG Barman backups + MariaDB native backups → RGW (§1), etcd + `/etc/kubernetes/pki`
snapshot CronJob → RGW (§2 cluster-state), backup-failure/staleness alerts incl. CNPG base-backup
(§5), Loki chunk storage → RGW (§4), **L2 non-DB PVC backups via `kopiur`** (§2 L2) — live on
29 apps, hourly schedule, confirmed working end-to-end, **auto-restore-on-rebuild also live**
(all 22 backed-up apps wired to kopiur's `Restore` CSI populator, individually migrated and
verified — see `migration-inventory.md`), and **off-site (B2) is now live** (§2 L3) — both the
kopiur repo itself (`RepositoryReplication` → `kopiur-backups` bucket) and the RGW-sourced
DB/etcd backups (`rgw-nas-sync`'s B2 leg → a separate `ceph-rgw-backups` bucket), each confirmed
with a real end-to-end sync, not just applied-and-assumed-working. **Still open:** confirm the
sops age-key backup ×2 (§6, owner task), restore runbook (§6 — the testing itself is done),
grimmory-bookdrop's missing backup coverage (found during the restore migration, unrelated root
cause not yet investigated — see `migration-inventory.md` backlog). See the checklist in §8 for
per-item status.

Cluster facts that shape this: **vanilla Kubernetes via kubeadm** (stacked etcd as static pods
on the 3 control-plane nodes — *not* k3s), **Flux GitOps** (every workload + sops-encrypted
secret is in git), **Rook-Ceph** storage. Databases (10 CNPG PVCs + MariaDB + Redpanda) were
moved to the SSD tier `ceph-block-ssd`; bulk/media stays on HDD `ceph-block`.

---

## 1. What we are protecting against (failure model → tier)

| Failure | Example | Protected by |
|---------|---------|--------------|
| App-level mistake | dropped table, bad migration, config corruption | L0 snapshots, L1 DB PITR |
| Single PVC / RBD image loss | one volume corrupts | L1 (DB), L2 (files) |
| **Ceph / whole-cluster loss** | Ceph unrecoverable, cluster rebuilt | L2/L3 copies that live **off-Ceph** |
| Node / disk loss | a CP or worker disk dies | etcd HA + PKI/etcd backup; Ceph replication |
| **Site loss** | fire / theft / ransomware | **off-site** copy (L3) |
| **Secret/key loss** | sops age key gone | key backed up off-cluster ×2 (§6) |

**The load-bearing insight:** a backup only counts against a failure if the backup does **not
share fate** with the thing it protects. Live DBs run on Ceph, so a backup stored *in Ceph*
(RGW) does **not** protect against Ceph/cluster loss — only against app-level mistakes and
single-PVC loss. Real DR requires copies on the **NAS** (off-Ceph) and **off-site**.

---

## 2. Decision — layered backups

### L0 — Ceph VolumeSnapshots (same-cluster, fast rollback; NOT DR)
`snapshot-controller` + `csi-ceph-blockpool` / `csi-ceph-filesystem` VolumeSnapshotClasses
already exist. Add a **scheduled** snapshot policy (e.g. `snapscheduler`, or Velero-driven) for
cheap "undo" of a bad change. Same failure domain as the data → **not a backup**, just fast
rollback. Low priority; nice once the rest exists.

### L1 — Database-native backups (the important one for our DBs)
Filesystem-copying a live database is only crash-consistent. Use each operator's native,
consistent, point-in-time-capable backup instead, targeting S3:

- **CloudNativePG (5 clusters):** Barman Cloud object-store backup — continuous **WAL
  archiving** + scheduled base backups → **PITR**. `ScheduledBackup` CR per cluster + the
  cluster's `.spec.backup.barmanObjectStore` (or the newer Barman Cloud Plugin) pointed at an
  S3 bucket. Pure GitOps, fits the repo. Retention via Barman policy.
- **MariaDB (grimmory):** mariadb-operator native `Backup` CR (scheduled) → S3 or PVC, with a
  matching `Restore` CR path. 
- **Redpanda:** topic data is largely a transient bus (Akvorado flow ingest). Tiered
  storage/`rpk` topic export to S3 is possible but **low value** — treat as recreate-fresh
  unless a concrete need appears. Decide explicitly, don't back up on reflex.

### L2 — File-level PVC backups (non-DB app data)
For PVCs that aren't operator-managed databases: immich library, paperless documents,
vaultwarden vault, arr configs, home-assistant config, etc.

**Decided: Kopia via `kopiur`** (home-operations' Kopia-native Kubernetes operator,
`kubernetes/apps/kopiur-system/`), not Volsync. One shared `ClusterRepository` backed by
inline NFS to a dedicated NAS export (`10.20.30.11:/backups`, chowned to the same UID/GID most
apps in this cluster run as), with per-app `SnapshotPolicy`/`SnapshotSchedule` CRs via a reusable
Kustomize component, plus a read-only web UI (`kopiur.internal.oreillys.io`). **Status: live,
29 apps**, hourly schedule, confirmed via manual and scheduled snapshot runs.

Hard-won gotchas from the rollout (worth reading before touching this again):
- **RBD `snapshotPolicy` CSI default is `none`, not `volumeSnapshot`** (unlike CephFS, which
  defaults to `volumeSnapshot`) — without setting it explicitly on `ceph-csi-drivers`'
  `drivers.rbd.snapshotPolicy`, the `csi-snapshotter` sidecar never deploys and every
  `VolumeSnapshot` sourced from a `ceph-block`/`ceph-block-ssd` PVC hangs forever. This was the
  root cause that blocked the whole system before the first successful backup.
- **Cross-namespace credentials need a two-sided opt-in**: the `ClusterRepository`'s
  `credentialProjection.allowed: true` (owner) plus each `SnapshotPolicy`'s
  `credentialProjection.enabled: true` (consumer) — mover Jobs run in the app's own namespace,
  not `kopiur-system`, so `envFrom` can't reach the credentials Secret without both sides.
- **Non-UID-1000 apps need explicit mover identity work.** `inheritSecurityContextFrom.pvcConsumer`
  (added to the shared component) auto-matches apps that pin `runAsUser` at the pod/container
  level, but silently falls back to the UID-1000 default for anything image-default-only —
  invisible in the pod spec, so it can't be inherited. Worse: the NAS's `/repo` blobs are
  `0600`, owned exactly `1000:1000` — no group/world bits at all — so **only an exact UID match
  or root (via the NFS server's `no_root_squash`) can write to the repo**, and root also needs
  `capabilities.add: [DAC_OVERRIDE]` explicitly re-added (the mover's hardened base drops all
  capabilities by default) to read source files it doesn't exactly own. Net: any app not
  natively at UID 1000 needs `mover.securityContext: {runAsUser: 0, runAsGroup: 0,
  runAsNonRoot: false, capabilities: {add: [DAC_OVERRIDE]}}` on its `SnapshotPolicy`.
- **Root movers need a per-namespace opt-in.** kopiur gates any privileged mover request (UID 0,
  added capabilities) behind a `kopiur.home-operations.com/privileged-movers: "true"` annotation
  on the consuming namespace — without it, kopiur silently downgrades to the UID-1000 default
  rather than erroring, which looks identical to the original failure.
- **Flux `patches:` target-matching happens before `postBuild.substitute` runs** — a patch
  targeting a resource by its post-substitution name (e.g. `name: qui`) silently matches nothing,
  since at patch-match time the resource is still literally named `${APP}`. Match on `kind:` alone
  when there's only one resource of that kind per Kustomization.
- **`dataSourceRef` and the actual PVC migration must land as one atomic change, never
  decoupled.** Committing `dataSourceRef` to git ahead of deleting/recreating that app's live PVC
  doesn't just sit inert — Helm applies a release's full desired state as one operation, so every
  future change to that app (a Renovate image bump, any unrelated edit) hits the same
  immutable-field conflict and gets rolled back, indefinitely, until the PVC actually gets
  migrated. Learned the hard way (#474 reverted by #480) before settling on migrating app-by-app,
  each one delete-verify-then-commit.
- **Restore's repository connection is read-only by design** (a restore should never write to the
  backup repo) **but kopia's own notification-listing path triggers an incidental manifest
  auto-compaction that tries to write anyway**, failing outright against the read-only mount. A
  failed `Restore` is terminal (kopiur never retries it) - the fix is deleting and recreating the
  `Restore` CR, which succeeds on retry. Hit this on both thelounge and immich during the restore
  migration.
- **A CSI populator can restore a PVC's bytes faithfully while still leaving an app broken**, if
  something *else* (a database) has state that assumes the disk's prior contents. Hit exactly this
  with immich: Postgres had folder-integrity markers recorded from an earlier partial setup, the
  freshly-restored (genuinely empty) disk had none, and `immich-server` crash-looped until the
  missing `.immich` marker files were manually recreated. Not a kopiur/populator bug - would recur
  on any fresh volume (a real rebuild included) paired with DB state that doesn't match.

**Restore-on-rebuild is now live** (kopiur's `Restore` CRD as a CSI volume populator,
`persistence.<name>.dataSourceRef`) across all 22 backed-up apps — see `migration-inventory.md`
for the full app-by-app rollout and the two real bugs it surfaced (bazarr's Kustomization, the
immich folder-integrity mismatch). **Off-site sync to B2 is also now live** — see §2 L3 below.

### L3 — Off-site (DONE — 2026-08-15)
NAS is copy #2, **not DR** — the disk plan itself notes the NAS mirror pool "is not a backup."
Fire/theft/ransomware takes cluster **and** NAS. Two independent B2 legs, kept in **separate
buckets with separately-scoped Application Keys** (deliberate — a leaked/misused key for one
can't touch the other):

- **kopiur's own repo → `kopiur-backups` bucket.** `RepositoryReplication` CR
  (`kubernetes/apps/kopiur-system/kopiur/repository/replication.yaml`) does a blob-level
  `kopia repository sync-to` from the NAS repo, daily at 06:00, `deleteExtra: true` (true
  mirror — GFS-pruned blobs on the NAS get pruned in B2 too, no separate off-site retention
  policy needed). Destination inherits the source repo's password verbatim.
- **RGW-sourced DB/etcd backups → `ceph-rgw-backups` bucket.** `rgw-nas-sync`
  (`kubernetes/components/rgw-nas-sync/`) got a second `rclone sync` leg alongside its existing
  NAS sync, same mirror logic — CNPG's `retentionPolicy: 14d` and mariadb-operator's
  `maxRetention: 720h` already self-prune at the RGW source, so `rclone sync` (not `copy`)
  propagates that pruning to B2 automatically, no new logic needed.

**Gotcha worth remembering:** kopia shards blobs into nested directories (`p00/`, `p01/`, ...)
only on **filesystem** backends, to keep any one directory's entry count sane on a real
filesystem. Object stores like B2 don't have that constraint, so kopia's B2/S3 blob driver
stores every blob as a flat key (the blob ID itself, no `/`) at the bucket root — confirmed by
listing the bucket directly (`rclone lsf b2:kopiur-backups --dirs-only` returns nothing) and
cross-checking the object count against the NAS-side file count. Same encrypted content, just a
different per-backend storage-key convention — not a sign anything's wrong, and unrelated to
encryption.

**Also fixed along the way:** the kopiur `ClusterRepository`'s NFS backend originally pointed at
the NAS export root (`/backups`), so its blob shards sat as loose siblings of `rgw-nas-sync`'s
own `rgw-sync/` directory in the same export. Moved into its own `/backups/kopiur` subdirectory
(PR #490) — required physically moving the existing repo's files on the NAS first, then letting
the controller re-detect the existing repo at the new path (confirmed via the `Bootstrapped`
condition: "connected to the existing repository", not a fresh create).

### Cluster-state (kubeadm-specific — differs from the old k3s cluster)
kubeadm stacked etcd has **no** k3s `--etcd-s3` convenience. For a GitOps cluster the workloads
are all re-appliable from git, so this is lower priority than L1/L2 **but** cheap insurance and
it's the only copy of two rebuild-critical, not-in-git artifacts:
- **etcd snapshot:** `etcdctl snapshot save` against the static-pod etcd (needs
  `/etc/kubernetes/pki/etcd/{ca,server}.*` client certs) — run as a host systemd timer on a CP
  node, or an in-cluster CronJob mounting the certs → write to NAS/S3.
- **`/etc/kubernetes/pki`** (the cluster **CA** + `sa.key` especially) — lives on the CP nodes'
  filesystems, not in etcd. Without the CA a restore/rejoin can't match issued certs. Tar it
  off-node alongside each etcd snapshot.

**DONE (2026-08-02):** `kubernetes/apps/kube-system/etcd-backup/` — a CronJob (every 6h) pinned
to a control-plane node (nodeSelector + toleration, `hostNetwork` to reach `127.0.0.1:2379`)
runs `etcdctl snapshot save` **and** tars `/etc/kubernetes/pki`, then an `rclone` sidecar pushes
both to a timestamped prefix in the `etcd-backup` RGW bucket (14-day retention). This is the
in-cluster/off-CP-node copy; the **off-Ceph** DR copy still rides the NAS sync (below). Alerts:
`EtcdBackupStale` / `EtcdBackupJobFailing`.

Note: because everything else is in git + Flux, a total loss can also be handled by
`kubeadm init` fresh + Flux re-reconcile — the etcd/PKI backup is what turns a multi-hour
rebuild into a restore, and preserves anything created imperatively (see §6).

---

## 3. The S3 target — Ceph RGW now, NAS/off-site as the durable tier

`cephObjectStores: []` today. Stand up a Rook **CephObjectStore** (RGW) to get an in-cluster,
S3-compatible endpoint:
- `CephObjectStore` (RGW pool — **`deviceClass hdd`**, this is bulk backup data), a
  `CephObjectStoreUser` (or `ObjectBucketClaim`s) per consumer, buckets like `cnpg-backups`,
  `mariadb-backups`, and later `loki-chunks`.

**Why RGW even though it shares fate with Ceph:** it (1) proves the whole S3 backup path
end-to-end without waiting on the NAS, (2) gives fast same-cluster restores for the common case
(bad migration / dropped table / PITR), and (3) is the storage backend Loki wants (see §4).
**But the DR copy must leave Ceph:** the RGW buckets get synced to the NAS (Kopia/rclone), and
the NAS to off-site. So the flow is:

```
DB-native backup ──► RGW (S3)  ──sync──►  NAS  ──kopia──►  off-site (B2/R2)
   (PITR, fast restore)      (off-Ceph DR)         (site-loss DR)
```

`external-s3-later`: pointing CNPG/MariaDB directly at B2/R2 (skipping RGW) is a one-line target
swap if we decide the RGW hop isn't worth it — the DB-native config is target-agnostic.

---

## 4. Loki storage on RGW (phase 2, unblocks retention/HA)
The network-observability plan flagged Loki HA/retention as blocked on an S3 backend.

**DONE (2026-08-02):** Loki (`SingleBinary`) switched from `filesystem` to the RGW `loki` bucket
(S3). Clean break — pre-switch chunks on the PVC are no longer queryable but age out within the 14d
retention; the PVC stays for WAL/active tsdb index + compactor/ruler working dirs (ruler storage is
still `local`, rules come from the sidecar). Credentials come from the `loki-bucket` OBC Secret via
`-config.expand-env=true` + `extraEnvFrom`. This is durable chunk storage + retention, not off-Ceph
DR (RGW shares fate with Ceph). See `observability/loki/app/{helmrelease,obc}.yaml`.

---

## 5. Monitoring the backups
A backup nobody watches rots silently.

**DONE (2026-08-02):** alerts wired into the existing Alertmanager→Slack path:
- **etcd/PKI** — `EtcdBackupStale` (>14h since a successful run), `EtcdBackupJobFailing`
  (`kubernetes/apps/kube-system/etcd-backup/app/prometheusrule.yaml`).
- **CNPG** — `CNPGWALArchiveFailing` (new `pg_stat_archiver` failures) and `CNPGWALArchiveBacklog`
  (WAL `.ready` files piling up) cover the **continuous/PITR** side.
- **MariaDB** — `MariaDBBackupJobFailed` + `MariaDBBackupStale` via `kube_job`/`kube_cronjob`
  metrics (the operator runs backups as native CronJobs).
  (`kube-prometheus-stack/app/backup-prometheusrules.yaml`.)

**Gotcha that shaped this:** CNPG's built-in backup-catalog metric
`cnpg_collector_last_available_backup_timestamp` reads **0** on the **Barman Cloud plugin** path
(only the deprecated in-tree `barmanObjectStore` populated it), so it can't be used for
last-good-backup alerting. The `pg_stat_archiver_*` metrics are used instead.

**DONE (2026-08-02):** CNPG **base**-backup staleness (distinct from WAL archiving). A
**kube-state-metrics CustomResourceState** on `backups.postgresql.cnpg.io` exposes
`.status.stoppedAt` (CRS Gauge auto-parses RFC3339 → unix seconds) labelled by `cnpg.io/cluster`
and `phase`; failed/running backups have a null `stoppedAt` so emit no series. Alert
`CNPGBaseBackupStale` fires when `time() - max by(cluster)(cnpg_backup_stopped_at{phase="completed"})`
exceeds 30h (daily schedule). KSM config lives in `kube-prometheus-stack/app/helmrelease.yaml`
(with `rbac.extraRules` for the CRD); the rule is in `backup-prometheusrules.yaml`. Edge case: a
cluster with no completed base backup yet emits no series and can't fire this — WAL/ScheduledBackup
signals cover that bootstrap window. (MariaDB base backups are covered via `kube_job`.)

## 6. Secrets & rebuild runbook (highest-consequence, lowest-effort)
- **SOPS age private key** — if lost, *every* secret is unrecoverable and the cluster can't be
  bootstrapped from git. Confirm it's backed up in **≥2 places, off-cluster and off-site**
  (password manager + printed/second location). Do **not** store it in this repo. This is the
  single most important DR item and it's currently undocumented.
- **Flux bootstrap runbook** — write the exact rebuild path: restore age key → `flux bootstrap`
  → reconcile order → restore etcd/PKI (if restoring vs rebuilding) → restore L1/L2 data.
  Capture **imperative, not-in-git** state here too (e.g. the Ceph CRUSH hdd-rule swap done
  2026-07-30 on the pre-existing pools — see `ceph-device-class-tiering`).

## 7. Dead-man's switch (DR-adjacent, do early — it's cheap)
`Watchdog` alert is routed to `null` today → no external liveness. Route it to a webhook that
pings an **external** heartbeat (healthchecks.io, or self-hosted off-cluster) every
`repeatInterval` (5m); silence >grace pages you via a channel independent of the cluster. The one
failure you can't self-report ("the alerter/cluster/internet is down") — see
`kube-prometheus-stack/app/alertmanagerconfig.yaml`.

---

## 8. Implementation order (proposed)
1. ✅ **Dead-man's switch** — closes the scariest blind spot. (§7)
2. ⬜ **Confirm sops age-key backup** off-cluster ×2 — removes the worst "can't rebuild". **Owner task.** (§6)
3. ✅ **CephObjectStore (RGW)** + buckets — the S3 target everything else needs. (§3)
4. ✅ **CNPG Barman backups** → RGW (Barman Cloud **plugin**). (§1)
5. ✅ **MariaDB native backup** → RGW. (§1)
6. ✅ **RGW → NAS sync** (`components/rgw-nas-sync`, rclone) — makes DB backups actual DR. Live
   on all 8 RGW buckets (loki deliberately excluded — RGW is its primary storage, not a backup
   of it).
7. ✅ **Kopia (`kopiur`) for non-DB PVCs** → NAS. Decided over Volsync. Live on 29 apps, plus
   restore-on-rebuild (CSI populator) live on all 22 backed-up apps. (§2 L2)
8. ✅ **Off-site** from NAS to B2 — two independent legs (kopiur's own repo via
   `RepositoryReplication`; RGW-sourced DB/etcd backups via `rgw-nas-sync`'s second B2 leg), each
   in its own bucket with a separately-scoped key. Both confirmed with a real sync. (§2 L3)
9. ✅ **etcd + /etc/kubernetes/pki** snapshot CronJob → RGW. (§2 cluster-state)
10. ✅ **Loki → RGW** storage. (§4)
11. ✅ **Backup monitoring** alerts — etcd + CNPG WAL + CNPG base-backup (KSM CustomResourceState)
    + MariaDB + RGW→NAS sync all done. (§5)
12. 🟡 **Restore testing + runbook** — the *testing* half is now extensively proven (all 22
    kopiur-backed apps individually restore-tested live, real data + ownership verified per app,
    see `migration-inventory.md`); a written runbook capturing the actual procedure (and the
    non-obvious failure modes hit along the way — Restore's terminal-on-failure behavior, the
    Helm/`dataSourceRef` immutable-field dance, DB/disk state mismatches) still doesn't exist.
13. ⬜ **Scheduled VolumeSnapshots** (L0) — nice-to-have rollback. (§2 L0)

**Next up:** (2) age-key confirmation [owner] is the only fully-unstarted item and needs no NAS.
(6), (7), (8), and (11) are all done now, so (12) — the restore runbook — is the next real backup
item, and it's mostly writing down what's already been proven live rather than new work. (13) is
a low-priority nice-to-have.

## 9. Open questions
- RGW-then-sync-to-NAS vs. MinIO-on-NAS as the primary S3 (RGW shares fate with Ceph; MinIO-on-NAS
  is off-Ceph from the start but is more to run). Starting with RGW to prove the path.
- Retention policies per tier (PITR window for CNPG; kopiur's GFS retention for files — currently
  `keepLatest: 3, keepHourly: 24, keepDaily: 7, keepWeekly: 4` uniformly, not yet reviewed per-app).
- Whether Redpanda gets any backup at all (leaning no).
