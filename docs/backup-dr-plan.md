# Backup & Disaster Recovery Plan (ADR)

Status: **Partially implemented** (updated 2026-08-12). Companion to `disk-hardware-plan.md`,
`node-inventory.md`, `migration-inventory.md`. **Done:** dead-man's switch (§7), Ceph RGW S3
target (§3), CNPG Barman backups + MariaDB native backups → RGW (§1), etcd + `/etc/kubernetes/pki`
snapshot CronJob → RGW (§2 cluster-state), backup-failure/staleness alerts incl. CNPG base-backup
(§5), Loki chunk storage → RGW (§4). **In progress:** L2 non-DB PVC backups via `kopiur`
(Kopia-native operator, §2 L2) — NAS is up and the design is settled, PR open (draft) covering
vaultwarden + home-assistant as a first wave, not yet merged. **Still open:** off-site from NAS to
B2 (§2 L3, deliberately deferred until the NAS tier is proven), confirm the sops age-key backup ×2
(§6, owner task), restore runbook + testing (§6). See the checklist in §8 for per-item status.

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
`kubernetes/apps/kopiur-system/`, PR #436), not Volsync. One shared `ClusterRepository`
backed by inline NFS to a dedicated NAS export (`10.20.30.11:/backups`, chowned to the same
UID/GID every app in this cluster already runs as), with per-app `SnapshotPolicy`/
`SnapshotSchedule` CRs. **Status: draft, first wave only** (vaultwarden, home-assistant) as a
proving-ground before the rest of the L2 list. Off-site sync to B2 is a deliberate follow-up
via kopiur's `RepositoryReplication` CRD (mirrors an existing repo's blobs to a second backend
on a schedule) — not yet built, but bolts on without touching the NAS-side config once this is
proven. See `migration-inventory.md`'s backlog for the rollout-to-remaining-apps step.

### L3 — Off-site (deferred, but not optional long-term)
NAS is copy #2, **not DR** — the disk plan itself notes the NAS mirror pool "is not a backup."
Fire/theft/ransomware takes cluster **and** NAS. Plan (per stated intent): land L1/L2 backups on
the **NAS** in a layout that a **Kopia** job on/near the NAS then syncs to **off-site**
(Backblaze B2 / Cloudflare R2 — both S3-compatible, cheap). Get NAS-tier working first; wire
off-site once proven. Barman/restic/Kopia all target B2/R2 directly if we later skip the NAS hop.

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
6. ⬜ **RGW → NAS sync** (Kopia/rclone) — makes DB backups actual DR. NAS is up; not started.
7. 🟡 **Kopia (`kopiur`) for non-DB PVCs** → NAS. Decided over Volsync. PR open (draft, first
   wave vaultwarden + home-assistant), not yet merged. (§2 L2)
8. ⬜ **Off-site** from NAS (B2/R2) — via `kopiur`'s `RepositoryReplication`. Deliberately
   deferred until item 7's NAS tier is proven, not NAS-gated in the old sense. (§2 L3)
9. ✅ **etcd + /etc/kubernetes/pki** snapshot CronJob → RGW. (§2 cluster-state)
10. ✅ **Loki → RGW** storage. (§4)
11. ✅ **Backup monitoring** alerts — etcd + CNPG WAL + CNPG base-backup (KSM CustomResourceState)
    + MariaDB all done. (§5)
12. ⬜ **Restore testing + runbook** — periodic, documented. *(no NAS needed for the runbook)*
13. ⬜ **Scheduled VolumeSnapshots** (L0) — nice-to-have rollback. (§2 L0)

**Next up:** (2) age-key confirmation [owner] and (12) restore runbook need no NAS and aren't
started. (7) is in progress (PR open). (6) and (8) are next once (7) is proven live.

## 9. Open questions
- Volsync vs standalone Kopia for L2 (leaning Volsync — ecosystem fit).
- RGW-then-sync-to-NAS vs. MinIO-on-NAS as the primary S3 (RGW shares fate with Ceph; MinIO-on-NAS
  is off-Ceph from the start but is more to run). Starting with RGW to prove the path.
- Retention policies per tier (PITR window for CNPG; restic keep-policy for files).
- Whether Redpanda gets any backup at all (leaning no).
