# Disk / Storage Hardware Plan

Status: **in progress** (updated 2026-08-15). Source inventory: `disk-inventory` (root of repo).

**Done:** 6 OSDs deployed and auto-classed (3× HDD, 3× SSD); WD Blue landed on `wk-drotte` as
the 3rd SSD OSD, so `ceph-blockpool-ssd` is back to `size: 3` (no longer running degraded at
`size: 2`); Ceph split into device-class tiers — DBs on `ceph-block-ssd`, bulk on `ceph-block`
(see `ceph-device-class-tiering` memory); CephObjectStore/RGW being added as the backup S3
target (`backup-dr-plan.md`). **etcd S3610 PLP swap done (2026-08-15)** — all 3 CP nodes
(`cp-gurloes`/`cp-malrubius`/`cp-palaemon`) rebuilt one-at-a-time onto Intel DC S3610 200GB via
kubeadm etcd-member replacement (drain → remove etcd member → swap disk → reprovision → rejoin);
freed the 3 interim disks (Patriot P210 128GB, Intel 520 240GB, Samsung 870 EVO 500GB) for the
§2 block.db cascade.
**Pending:** block.db SSDs (roche/eata), `wk-eata` 10GbE NIC.
**NAS build is done** — `nas-ultan` has been re-laid to the §1 plan (3 mirror vdevs + cold
spare) and is live, serving NFS to the cluster (confirmed 2026-08-11; see `migration-inventory.md`).
Backups (`backup-dr-plan.md`) not yet implemented.

Goal: assign every usable disk to a role during the cluster + NAS rebuild, fix the
known pain (etcd fsync latency, Ceph HDD slow-ops), and keep spend near-zero given
current HDD prices. See related: `etcd-slow-commits-patriot-ssd`, `ceph-hdd-slow-ops`,
`ceph-etcd-ssd-hardware-plan`.

## Assumptions (correct if wrong)

- **bazzite-desktop** is a live workstation → drives are donor parts only if pulled. 850 EVO
  **250GB** is its OS disk (untouchable). The 850 EVO **1TB** (Steam-lib) IS being reclaimed.
- **WD60EFAX count = 5–6** (4 in ubuntu-01 + 1–2 spare) → NAS pool keeps a cold spare.
- Ceph OSDs are **not** co-located on control-plane/etcd nodes (Ceph IO wrecks etcd latency).
- Roles: 3 lean control-plane (the 8GB nodes) + 4 storage/compute workers (the 32GB/10GbE
  nodes) + 1 extra compute worker + 1 NAS.
- **The four 32GB workers are SATA-only (no M.2/NVMe).** NVMe drives can only live on
  `wk-jonas` (MFF: M.2 + one 2.5" bay) and the CP Dells. This shapes OSD/block.db placement.

---

## 1. NAS node (`nas-ultan`) — ZFS, bulk data, primary copy

**Status: done (confirmed 2026-08-11)** — disks re-laid to this plan, pool live, serving NFS
to the cluster at `10.20.30.11`. Layout below is as-built, not aspirational.

**Pool: 3 × mirror vdevs = ~18 TB usable.** Mirrors (NOT RAIDZ) are the correct SMR
mitigation — mirror resilver is sequential, which DM-SMR tolerates; RAIDZ resilver is
the random-write pattern that faulted these drives in the 2020 WD Red debacle.

| vdev | drive A | drive B |
|------|---------|---------|
| mirror-0 | HGST HUS726060ALE611 6TB (CMR) | WD60EFAX 6TB (SMR) |
| mirror-1 | WD60EFAX 6TB (SMR) | WD60EFAX 6TB (SMR) |
| mirror-2 | WD60EFAX 6TB (SMR) | WD60EFAX 6TB (SMR) |
| spare | WD60EFAX 6TB (SMR), cold | |

SMR-in-mirror survival checklist:
- **Raise SCSI command timeout to 180s** (`echo 180 > /sys/block/sdX/device/timeout`,
  persist via udev) so ZFS doesn't fault a drive doing background media-cache cleaning.
- **Keep pool < 80% full** — SMR degrades hard when full.
- Pair the lone CMR (HGST) with an EFAX so one vdev has a fast/reliable half.
- Keep the cold spare so resilvers happen promptly.
- Expect slow scrubs; schedule off-peak.
- Optional perf: mirrored SSD **special vdev** (metadata + small blocks) offloads the
  random writes SMR hates — biggest win, but its loss = pool loss, so must be a mirror.
  Zero-risk alternative: single-SSD **L2ARC** for reads.
- This is a mirror pool, **not a backup** — keep an offsite/second copy of what matters.

Chassis SSDs: **Crucial M4 64GB → NAS boot disk.** The WD Blue 1TB SATA and one X400 128GB
are being **pulled into the cluster** (Ceph SSD OSD + worker OS) → NAS keeps only the M4 for
boot, so there's no spare SSD left for a special-vdev/L2ARC unless you add one later.

---

## 2. Rook-Ceph — hybrid SSD + HDD OSD tiers

**OSD hosts = the four 32GB / 10GbE machines** (old cp-01/cp-02/cp-03/wk-03), repurposed as
storage+compute workers, + one **extra compute worker** (old wk-01, 16GB). Both tiers
replicated ×3 (host failure domain). Names = Wolfe journeymen; disk→node binding is physical,
assign as you rack them.

| hostname | was | RAM | OS disk | Ceph OSDs |
|----------|-----|-----|---------|-----------|
| `wk-severian` | cp-01 | 32G, 2-bay | Patriot P210 128GB | **SSD** — 850 EVO 1TB (**placed**) |
| `wk-drotte`   | cp-02 | 32G, 3+ conn | SanDisk X400 128GB | **HDD** HGST 2TB (placed) **+ SSD** WD Blue (**placed**); HGST block.db **colocated** |
| `wk-roche`    | cp-03 | 32G, 3+ conn | SanDisk X400 128GB | **HDD** WD20EARX 2TB (placed) **+ block.db SSD** (spare conn) |
| `wk-eata`     | wk-03 | 32G, 3+ conn | Patriot P210 128GB | **HDD** WD20EARX 2TB (placed) **+ block.db SSD** (spare conn) |
| `wk-jonas`    | wk-01 | 16G (MFF, M.2)  | Patriot P210 128GB | **SSD** SN770M NVMe (placed) |

*Current physical state above.* Required moves are **done** (HGST → drotte, 1× EARX → eata,
WD Blue → drotte).

> **Bay constraint (resolved):** these ex-CP boxes are tight but each has **≥1 spare data
> connector** beyond OS + one OSD. Final placement:
> - `severian` (2-bay) → OS + **SSD** OSD (850); can't take a 3.5" HDD alongside its OS.
> - `drotte` → OS + **HDD** (HGST) + **SSD** (WD Blue) in its 3rd connector → HGST block.db colocated.
> - `roche` / `eata` → OS + **HDD** (EARX) + **block.db SSD** in the spare connector.
> - `jonas` (MFF) → OS + **SSD** (SN770M, NVMe).
>
> Net: tiers overlap only on drotte; block.db-on-SSD lands on the EARX drives (where it matters),
> HGST runs colocated.

### SSD OSD tier — 3 OSDs, **complete**
| drive | host | status |
|-------|------|--------|
| WD_BLACK SN770M 1TB NVMe | `wk-jonas` (MFF, only NVMe-capable worker) | **placed** |
| Samsung 850 EVO 1TB (SATA) | `wk-severian` | **placed** |
| WD Blue 1TB SATA SSD (WDBNCE0010P) | `wk-drotte` (3rd connector, alongside HGST) | **placed** |

3 SSD hosts = `jonas` + `severian` + `drotte`. SN770M is NVMe → jonas only; the two SATA SSDs
(850, WD Blue) go on the SATA-only workers. Because drotte spends its 3rd connector on the SSD
OSD, its HGST runs block.db colocated (fine — healthiest drive; see block.db below).

**WD Blue reclaimed.** The old-cluster Longhorn remnant it served has been migrated/torn down;
the drive is now the 3rd SSD OSD on `wk-drotte`. `ceph-blockpool-ssd` is back to `size: 3`
(was temporarily `size: 2` while only 2 SSD hosts existed).

### HDD OSD tier — 3 OSDs, **placed** — block.db (see gap below)
| drive | host | status |
|-------|------|--------|
| HGST HUA723020ALA640 2TB | `wk-drotte` | **placed** (moved from cp-gurloes) |
| WDC WD20EARX 2TB | `wk-roche` | **placed** |
| WDC WD20EARX 2TB | `wk-eata` | **placed** (moved from cp-malrubius) |

3 HDD hosts = exactly size=3, **no 4th-host headroom** (severian is SSD + 2-bay → can't do a
3.5" HDD alongside its OS). Spare EARX → cold spare. wk-03's ST500DM002 500GB → retire.

**block.db — covered, no buy.** The EARX drives are the slow-ops-prone ones, so that's where
block.db-on-SSD matters most — and `roche`/`eata` each have a spare connector for it:
- **roche + eata** EARX OSDs each get a dedicated SATA block.db SSD (~60GB; RocksDB steps
  30/60/300) → **Intel Pro 1500 180GB** (on hand now) + one cascade SATA (870 EVO or Intel 520,
  once the S3610s free it).
- **drotte's HGST** runs block.db **colocated** (its 3rd connector holds the WD Blue SSD OSD) —
  least-bad place to colocate, since enterprise CMR handles inline block.db far better than EARX.

Set block.db at **OSD-create time**. If you bring an EARX up colocated during testing, you'll
recreate it (or `ceph-bluestore-tool bluefs-bdev-new-db`) to attach the SSD later.

Hitachi HUS724030ALE641 3TB (bazzite, enterprise CMR) — optional extra HDD OSD or NAS drive
if pulled.

---

## 3. Control plane / etcd (3 nodes) — low-latency, ideally PLP

**Status: DONE (2026-08-15).** All 3 CP nodes now run etcd on Intel DC S3610 200GB
(SSDSC2BX200G4R) — MLC + PLP + ~3 DWPD, the correct etcd disk (small is fine, etcd DB is a few
GB). All three CP nodes are the **8GB machines** → the intentional lean/dedicated control plane.

Naming: Gene Wolfe *Book of the New Sun*, guild-masters faction = control plane
(continues the Wi-Fi SSID theme).

| hostname | machine | etcd disk | freed interim disk |
|----------|---------|-----------|---------------------|
| `cp-palaemon` | Lenovo (8GB) | **S3610 200GB (placed)** | Intel 520 240GB (2.5" SATA) |
| `cp-gurloes` | Dell 7050 (was test-01) | **S3610 200GB (placed)** | Patriot P210 128GB |
| `cp-malrubius` | Dell 7050 (was wk-02) | **S3610 200GB (placed)** | Samsung 870 EVO 500GB |

All CP-only, **tainted NoSchedule**. Every Patriot is now out of etcd.

**Swap procedure used:** rolling, one node at a time (etcd is a 3-node quorum — never touch two
at once). Per node: drain → `etcdctl member remove` → power off → swap disk → PXE-boot fresh
Flatcar → `kubeadm join --control-plane` (fresh join+cert, not a disk clone — see reasoning
below) → verify etcd/apiserver/kube-vip-cp healthy → next node. Surfaced and fixed along the way:
a missing `controlPlaneEndpoint` in the live `kubeadm-config` ConfigMap (nodes were discovering
via a single hardcoded node IP baked into the `cluster-info` ConfigMap at original bootstrap,
not the VIP), a resulting apiserver cert/`--service-cluster-ip-range` mismatch on the
first-rejoined node, and etcd/controller-manager/scheduler metrics bound to `127.0.0.1` instead
of `0.0.0.0` (silently broke Prometheus scraping — `etcdInsufficientMembers` alerts, not an
actual outage). All fixed live and closed permanently in the `kubernetes-cluster` ansible repo
(the `ClusterConfiguration` re-upload task now runs on every playbook execution instead of only
a from-scratch bootstrap, so it self-heals instead of silently drifting again).

**Why reprovision instead of disk-cloning:** two of the three interim disks (240GB, 500GB) were
*larger* than the 200GB S3610, so a block-level clone wasn't even mechanically straightforward.
More fundamentally, these nodes run Flatcar (immutable, Ignition-provisioned) and etcd is
designed for member replacement (remove/rejoin, raft resync) — fighting either of those with a
disk clone would have been working against the grain for no benefit, especially with the
etcd+PKI backup CronJob already in place as the safety net (`backup-dr-plan.md`).

**Disk cascade — freed interim disks now available:** Intel 520 240GB / Patriot P210 128GB /
Samsung 870 EVO 500GB. Best use is HDD-OSD block.db (§2 — Intel Pro 1500 180GB + one of
870 EVO/Intel 520 for roche/eata), still **bay-blocked** until eata/roche's spare connector is
used; Patriot P210 is low-endurance, keep off anything stateful.

**Form factor:** confirmed resolved — Lenovo (`cp-palaemon`) 2.5" SATA bay took the S3610
directly, same as the other two Dell 7050s.

---

## 4. Worker OS disks

Per-node OS disks are in the §2 roster. Supply: **SanDisk X400 128GB ×3** (old wk-01 + NAS
pull + one just found) → **Patriot P210 128GB ×4** fallback. Both are fine for a worker root
(not fsync-hot); Patriots are low-endurance, so keep them off anything stateful. Once the
S3610s land, the freed CP interim disks *could* upgrade worker roots — but they're more
valuable as HDD block.db devices (§2), so leave workers on X400/Patriot.

---

## 5. Retire / do-not-use-in-array

| drive | where | why |
|-------|-------|-----|
| WD60EFAX 6TB | ubuntu-01 | SMR — **ok in the NAS mirror pool only**, never Ceph/RAIDZ |
| ST2000DM008 2TB | bazzite | SMR |
| Kingston NV1 / NV2 NVMe | bazzite | QLC + DRAMless — desktop scratch only |
| ST500DM002 / ST500LM000 500GB | wk-03 / cp-01 | old, small, low value |
| CHN-mSATAM3-128, MZ7TE512, 840 EVO mSATA | k3os nodes | no-name / aged TLC |
| CF/xD/SD readers (0B) | wk-03 | not disks |

`ST500LM000` SMR status unconfirmed — irrelevant, retiring it anyway (slow 5400 laptop drive).

---

## 6. Buy list (prioritized, budget-aware)

1. ~~3 × enterprise PLP SATA SSD for etcd~~ → **DONE: 3× Intel DC S3610 200GB (SSDSC2BX200G4R) installed 2026-08-15.**
2. **block.db** — **covered, no buy.** roche/eata EARX get SATA block.db (Intel Pro 1500 180GB
   on hand + one cascade SATA — 870 EVO or Intel 520); drotte's HGST runs colocated. See §2.
3. ~~1–2 TLC 1TB SSD for the Ceph SSD tier~~ — **not needed** (SN770M + 850 EVO 1TB + WD Blue 1TB = 3 OSDs).
4. **No new HDDs** — NAS reuses EFAX+HGST, Ceph HDD tier reuses EARX + HGST 2TB.

---

## Open decisions / constraints

- **10GbE: RE-OPENED (2026-07-29 scan).** `wk-eata` shows **only onboard 1GbE** (`enp0s31f6`);
  the spare 10GbE NIC is **not installed/detected** — so only 3 of 4 OSD hosts (severian/drotte/
  roche, all `f0` @ 10000Mb/s) are actually on 10GbE. eata's HDD OSD recovery path is 1GbE until
  the card is seated. NAS (`nas-ultan`) has its Intel dual-port 10GbE **installed but link-down**
  (`enp2s0f0/f1` present, no speed); it's currently live on onboard 1GbE (`enp0s25`). Action:
  check eata's PCIe slot / reseat its NIC; patch + bring up nas-ultan's 10GbE. Then re-scan.
- **Bays: RESOLVED** — drotte/roche/eata each have ≥1 spare connector. drotte = 3rd SSD host
  (WD Blue) + colocated HGST block.db; roche/eata = block.db SSD alongside their EARX.
- **EFAX: RESOLVED** — 6 drives → 5 in the pool + 1 cold spare.

**All open decisions closed.** Remaining work is execution: attach block.db at OSD-create time
(§2); everything else (850/WD Blue reclaim, S3610 swap, NAS build) is done.

---

## 7. Future upgrades (post-build, prioritized)

Finish the baseline first (block.db SSDs — the S3610 swap is done). After that, in value order:

1. **Backups — highest value, now planned in detail.** See **`backup-dr-plan.md`** for the
   full architecture (DB-native PITR + file-level PVC + off-site, with a Ceph RGW S3 target).
   Still the biggest remaining risk-reducer; blocked only on standing up the S3 target + NAS.
2. **GPU / AI — done, proven working (2026-08-16).** The original blocker was etcd
   contention: `ollama` (GPU-wired, `runtimeClassName: nvidia` + `nvidia.com/gpu: 1`) sat
   parked at `replicas: 0` because booting it starved etcd's fsync on the OLD co-located CP
   nodes with Patriot SSDs. The new topology fixed that by design (dedicated + tainted CP
   nodes, etcd on PLP S3610s) — but `ollama` itself has since been **replaced by `llama-cpp`**
   (declarative model management, no `kubectl exec` required; see `kubernetes/apps/ai/llama-cpp`).
   Confirmed live on the GTX 745: model loads onto the GPU, inference works
   (`Phi-4-mini` Q4_K_M, ~5.8 tok/s generation). Maxwell runs LLMs *stably but slowly*, as
   expected. Free win now unblocked: `immich-ml` → `-cuda` image + GPU request, same as
   `llama-cpp`. A used **RTX 3060 12GB / 3090 24GB** remains a pure capability upgrade if
   better perf is wanted later (decoupled from cluster stability, also dodges Maxwell's
   deprecated-in-CUDA driver pain).
3. **Ceph 4th-host headroom — resilience.** Both OSD tiers are exactly size=3 → if an OSD host
   dies, Ceph runs degraded (can't re-replicate) until repaired. A 4th host per tier restores
   self-healing. Medium priority for a homelab (degraded ≠ data loss).
4. **RAM — only if metrics say so.** 32G workers look adequate; check Prometheus worker
   memory / OSD pressure before buying. CP 8G nodes are fine as-is. Don't buy on spec.
   *DIMM headroom is now mapped (see `node-inventory.md` → RAM/DIMMs):* the three DDR3 Haswell
   workers (severian/drotte/roche) **and the NAS are at their 32 GB platform ceiling** — no DIMM
   path, only a board/CPU swap. Only DDR4 nodes can grow: `wk-eata` →64 GB and `wk-jonas` →32 GB
   (both need module *swaps*, slots full), and the CP nodes have **empty DDR4 slots** (cheapest
   add) if 8 GB ever gets tight for the control plane.
5. **UPS (if none).** Cheap insurance for the whole cluster + the SMR ZFS pool against power
   events; complements the PLP SSDs.
