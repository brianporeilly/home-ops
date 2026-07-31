# Backup & Disaster Recovery Plan (ADR)

Status: **Draft / proposed** (2026-07-30). Companion to `disk-hardware-plan.md`,
`node-inventory.md`, `migration-inventory.md`. Nothing here is implemented yet — the cluster
currently has **zero backups of any kind** (no DB backups, no PVC backups, no etcd snapshot
upload, no scheduled volume snapshots). This doc decides the target architecture and order.

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
vaultwarden vault, arr configs, home-assistant config, etc. Options, both GitOps-native:
- **Volsync** (`ReplicationSource` per PVC, restic under the hood) — the idiomatic choice in
  the bjw-s/onedr0p home-ops ecosystem this repo already follows; per-PVC schedules, restic
  repos on NAS/S3, prune policies. **Recommended.**
- **Kopia** (standalone) — also fine; one repo, dedup, targets filesystem (NAS) or S3/B2/R2
  directly. Matches the "kopia/kopiur" tooling already in mind.

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
The network-observability plan flagged Loki HA/retention as blocked on an S3 backend. Once RGW
exists, switch Loki's `storage` to the RGW `loki-chunks` bucket (still `SingleBinary` is fine;
this is about durable chunk storage + retention, not necessarily HA). Optional, do after L1.

---

## 5. Monitoring the backups
A backup nobody watches rots silently. Once L1/L2 exist:
- Alert on **backup failure** and **staleness** (last-successful-backup age): CNPG exposes
  backup metrics; Volsync/restic and mariadb-operator expose status conditions → PrometheusRules.
- Add these to the existing Alertmanager→Slack path; treat a stale backup as `warning`, a failed
  backup run as `critical`.

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
1. **Dead-man's switch** — ~15 min, closes the scariest blind spot. (§7)
2. **Confirm sops age-key backup** off-cluster ×2 — 30 min, removes the worst "can't rebuild". (§6)
3. **CephObjectStore (RGW)** + buckets — the S3 target everything else needs. (§3)
4. **CNPG Barman backups** → RGW, PITR verified — protects the DBs we just tiered. (§1)
5. **MariaDB native backup** → RGW. (§1)
6. **RGW → NAS sync** (Kopia/rclone) — makes DB backups actual DR. (§3)
7. **Volsync/Kopia for non-DB PVCs** → NAS. (§2 L2)
8. **Off-site** from NAS (B2/R2). (§2 L3)
9. **etcd + /etc/kubernetes/pki** snapshot CronJob → NAS/S3. (cluster-state)
10. **Loki → RGW** storage. (§4)
11. **Backup monitoring** alerts. (§5)
12. **Restore testing + runbook** — periodic, documented. *(on the list, not immediate)*
13. **Scheduled VolumeSnapshots** (L0) — nice-to-have rollback. (§2 L0)

## 9. Open questions
- Volsync vs standalone Kopia for L2 (leaning Volsync — ecosystem fit).
- RGW-then-sync-to-NAS vs. MinIO-on-NAS as the primary S3 (RGW shares fate with Ceph; MinIO-on-NAS
  is off-Ceph from the start but is more to run). Starting with RGW to prove the path.
- Retention policies per tier (PITR window for CNPG; restic keep-policy for files).
- Whether Redpanda gets any backup at all (leaning no).
