# Node Inventory

Static inventory of cluster + NAS nodes. Naming: Gene Wolfe, *Book of the New Sun* —
guild masters = control plane, journeymen = workers, Ultan (the librarian) = NAS.

**Network:** `10.20.0.0/16`, segmented by **third octet = tier** (grow by 10s, room between).
Within each node tier, `.1–.10` are reserved (tier anchor / mgmt / future VIPs); **hosts start
at `.11`**. Keep static node IPs out of any DHCP dynamic pool. Blanks = not yet documented.

## Addressing plan

| Block | Tier |
|-------|------|
| `10.20.0.0/24`   | Networking / infra — gateway, switches, APs, PDU, BMC/IPMI |
| `10.20.10.0/24`  | Control plane |
| `10.20.20.0/24`  | Workers (storage / compute) |
| `10.20.30.0/24`  | NAS / storage appliances |
| `10.20.40.0/24`  | GPU / accelerator nodes — **reserved (future)**; current GPU boxes are tier-20 workers |
| `10.20.100.0/24` | DHCP dynamic pool — shrink OPNsense scope to here; nodes stay static reservations in tiers |
| `10.20.250.0/24` | LoadBalancer pool (existing, kube-vip-cloud-provider) |
| `10.20.254.0/24` | Cluster VIPs (existing — API `10.20.254.100`) |

## Reserved / infrastructure IPs

| IP | Purpose |
|----|---------|
| 10.20.0.1 | Gateway / router (kube-vip BGP peer) |
| 10.20.254.100 | Kubernetes API VIP (kube-vip) — **existing, keep** |
| 10.20.250.0/24 | LoadBalancer pool (kube-vip-cloud-provider `cidr-global`) |

## LoadBalancer service IPs (`10.20.250.0/24`)

| IP | Service |
|----|---------|
| 10.20.250.1 | envoy-external (gateway) |
| 10.20.250.2 | envoy-internal (gateway) |
| 10.20.250.3 | omada-controller |
| 10.20.250.4 | fluent-bit |
| 10.20.250.6 | akvorado |
| 10.20.250.10 | minecraft |
| 10.20.250.11 | frigate |

## Nodes — identity / compute / network

| Hostname | Role | Old name | Chassis | CPU | RAM | IP | NIC |
|----------|------|----------|---------|-----|-----|----|----|
| `cp-gurloes`   | control-plane (etcd) | k8s-test-01   | Dell OptiPlex 7050 | i7-7700 | 8 GB  | 10.20.10.11 | 1GbE |
| `cp-malrubius` | control-plane (etcd) | k8s-wk-02     | Dell OptiPlex 7050 | i7-7700 | 8 GB  | 10.20.10.12 | 1GbE |
| `cp-palaemon`  | control-plane (etcd) | — (new spare) | Lenovo ThinkCentre M900 Tiny (10MR0047US) | i5-6500T | 8 GB  | 10.20.10.13 | 1GbE |
| `wk-severian`  | worker (Ceph SSD OSD)      | k8s-cp-01 | Dell OptiPlex 9020 | i7-4770 (Haswell) | 32 GB | 10.20.20.11 | 10GbE |
| `wk-drotte`    | worker (Ceph HDD+SSD OSD, **GPU**) | k8s-cp-02 | Dell OptiPlex 9020 | i7-4790 (Haswell) | 32 GB | 10.20.20.12 | 10GbE |
| `wk-roche`     | worker (Ceph HDD OSD, **GPU**)     | k8s-cp-03 | Dell OptiPlex 9020 | i7-4790 (Haswell) | 32 GB | 10.20.20.13 | 10GbE |
| `wk-eata`      | worker (Ceph HDD OSD)      | k8s-wk-03 | Dell Precision Tower 3620 | Xeon E3-1270 v5 (Skylake, ECC-capable) | 32 GB | 10.20.20.14 | **1GbE ⚠** |
| `wk-jonas`     | worker (Ceph SSD OSD / compute) | k8s-wk-01 | HP EliteDesk 800 G2 DM (65W) | i5-6500 (Skylake) | 16 GB | 10.20.20.15 | 1GbE |
| `nas-ultan`    | NAS (ZFS)                  | ubuntu-01 | whitebox (ASRock, DMI OEM-blank) | Xeon E3-1230 v3 (Haswell, ECC) | 32 GB (4×8 DDR3-1333, **maxed**) | 10.20.30.11 | **1GbE ⚠** (10GbE present, link down) |

## Nodes — MAC addresses & firmware (for DHCP static reservations)

Use the **onboard 1GbE** MAC for OPNsense static reservations — PXE boots on the onboard NIC,
not the 10GbE add-in card. 10GbE NICs are Intel dual-port; only port-0 (`f0`) is patched
(`f1` reads `-1Mb/s` = link down, expected). Captured 2026-07-29.

| Hostname | Onboard NIC | Onboard MAC (DHCP) | 10GbE port-0 | 10GbE MAC | BIOS |
|----------|-------------|--------------------|--------------|-----------|------|
| `cp-gurloes`   | enp0s31f6 | `50:9a:4c:27:d7:e0` | — | — | 1.12.1 |
| `cp-malrubius` | enp0s31f6 | `50:9a:4c:22:93:c4` | — | — | 1.21.0 |
| `cp-palaemon`  | enp0s31f6 | `6c:4b:90:5a:fc:7e` | — | — | M1AKT56A |
| `wk-severian`  | eno1      | `34:17:eb:a5:c8:6f` | enp1s0f0 | `b4:96:91:08:cd:40` | A25 |
| `wk-drotte`    | eno1      | `98:90:96:bf:06:88` | enp5s0f0 | `a0:36:9f:de:6d:d0` | A10 |
| `wk-roche`     | eno1      | `98:90:96:be:3a:ff` | enp5s0f0 | `a0:36:9f:b6:69:6c` | A10 |
| `wk-eata`      | enp0s31f6 | `18:66:da:08:16:57` | ⚠ none detected | — | 2.22.0 |
| `wk-jonas`     | eno1      | `ec:8e:b5:6e:71:17` | — | — | N21 v02.19 |
| `nas-ultan`    | enp0s25   | `bc:5f:f4:fd:ec:92` | enp2s0f0 (link down) | `a0:36:9f:e5:70:78` | P1.70 |

## Nodes — RAM / DIMMs (upgrade headroom)

From `dmidecode -t 16/17`, 2026-07-29. "Board max" is what SMBIOS type-16 reports (= the
CPU/platform ceiling on these). Decision input for Future-upgrade #4 ("RAM only if metrics
say so"): the **DDR3 boxes are hard-capped**; the cheap headroom is on the CP nodes.

| Hostname | Installed | Slots | Modules | Type / speed | Board max | Headroom |
|----------|-----------|-------|---------|--------------|-----------|----------|
| `cp-gurloes`   | 8 GB  | 1 / 4 | 1×8 GB | DDR4-2400 UDIMM   | 64 GB | **3 slots free** — cheapest add |
| `cp-malrubius` | 8 GB  | 1 / 4 | 1×8 GB | DDR4-2400 UDIMM   | 64 GB | **3 slots free** — cheapest add |
| `cp-palaemon`  | 8 GB  | 1 / 2 | 1×8 GB | DDR4-2133 SODIMM  | 32 GB | **1 slot free** — cheap add |
| `wk-severian`  | 32 GB | 4 / 4 | 4×8 GB | DDR3-1600         | 32 GB | **maxed** — platform ceiling (DDR3) |
| `wk-drotte`    | 32 GB | 4 / 4 | 4×8 GB | DDR3-1600         | 32 GB | **maxed** — platform ceiling (DDR3) |
| `wk-roche`     | 32 GB | 4 / 4 | 4×8 GB | DDR3-1600         | 32 GB | **maxed** — platform ceiling (DDR3) |
| `wk-eata`      | 32 GB | 4 / 4 | 4×8 GB | DDR4-2133         | 64 GB | → 64 GB, but **no free slots** (4×16 swap) |
| `wk-jonas`     | 16 GB | 2 / 2 | 2×8 GB | DDR4-2133 SODIMM  | 32 GB | → 32 GB, but **no free slots** (2×16 swap) |
| `nas-ultan`    | 32 GB | 4 / 4 | 4×8 GB | DDR3-1333         | 32 GB | **maxed** — platform ceiling (DDR3) |

**Takeaways:** (1) the three DDR3 Haswell workers + the NAS are at their hard ceiling — more
worker/ARC RAM there means a board/CPU swap, not DIMMs. (2) Only DDR4 nodes can grow: `wk-eata`
(→64 GB) and `wk-jonas` (→32 GB) via *swaps* (slots full); the CP nodes grow by *adding* to empty
DDR4 slots — by far the cheapest headroom if 8 GB ever proves tight for etcd/control plane.

## Nodes — storage

| Hostname | OS / boot disk | Ceph OSDs / data disks | block.db | Notes |
|----------|----------------|------------------------|----------|-------|
| `cp-gurloes`   | **Patriot P210 128GB** (interim — slow) → **S3610 200GB** (pending) | — | — | tainted NoSchedule |
| `cp-malrubius` | Samsung 870 EVO 500GB → **S3610 200GB** | — | — | tainted NoSchedule; S3610 pending |
| `cp-palaemon`  | Intel 520 240GB (SSDSC2CW240A3) → **S3610 200GB** (etcd) | — | — | tainted NoSchedule; 2.5" bay; **+ Intel SSDPEKKF256G7L 256GB NVMe in M.2 (undocumented spare)**; S3610 pending |
| `wk-severian`  | Patriot P210 128GB | **SSD:** Samsung 850 EVO 1TB | — | 2-bay, SATA-only |
| `wk-drotte`    | SanDisk X400 128GB (SD8SB8U) | **HDD:** HGST HUA723020ALA640 2TB · **SSD:** WD Blue WDBNCE0010P 1TB · **GPU:** GTX 745 | HGST colocated | SATA-only; WD Blue **placed** — 3rd SSD OSD, `ceph-blockpool-ssd` back to `size: 3` |
| `wk-roche`     | SanDisk X400 128GB (SD8SB8U) | **HDD:** WD20EARX 2TB · **GPU:** GTX 745 | SATA SSD (pending) | SATA-only; block.db SSD not yet present |
| `wk-eata`      | Patriot P210 128GB | **HDD:** WD20EARX 2TB | SATA SSD (pending) | SATA-only; block.db SSD not yet present; ⚠ **10GbE NIC not detected** (only onboard 1GbE) |
| `wk-jonas`     | Patriot P210 128GB | **SSD:** WD_BLACK SN770M 1TB NVMe | — | MFF, M.2 |
| `nas-ultan`    | Crucial M4 64GB (boot) | **ZFS (planned):** 5× WD60EFAX 6TB + 1× HGST HUS726060ALE611 6TB (3 mirror vdevs) + 1× WD60EFAX cold spare | — | **disks to be re-laid to plan at teardown.** *Currently* (old cluster): 4× WD60EFAX + 1× HGST in ZFS; WD Blue 1TB SSD = `/data` (Longhorn — reclaim target); X400 128GB = `/var`; 6× iSCSI Longhorn PVCs mounted |

## Notes

- **etcd disks:** 3× Intel DC S3610 200GB (SSDSC2BX200G4R) incoming; interim disks listed above.
- **block.db (roche/eata HDD OSDs):** candidates = Intel Pro 1500 180GB (on hand) + one cascade
  SATA SSD (870 EVO or Intel 520, freed when S3610s land). drotte's HGST runs colocated.
- **Chassis swap of note:** the old control-plane boxes (k8s-cp-01/02/03) became workers; the new
  control plane is the 8GB machines (k8s-wk-02 + k8s-test-01 + a new Lenovo).
- **GPU nodes = `wk-drotte` + `wk-roche`** (old k8s-cp-02 @ `10.20.20.11`, k8s-cp-03 @ `.12`), each
  with an **NVIDIA GTX 745 (Maxwell)** — the *same machines* as two storage workers, not separate
  boxes. Driver: Flatcar `nvidia.service`, pinned 580.105.08 (last Maxwell branch); see
  `gpu-nodes-flatcar-nvidia` memory. These were GPU-bearing **CP nodes** in the old cluster (why
  ollama-on-etcd hurt) → now pure workers, which resolves it. Re-IP `.20.11/.12` → `.20.12/.13`;
  update ansible/SSH + the memory. `10.20.40.0/24` stays **reserved** for a *future* dedicated GPU node.
- **DHCP (OPNsense):** dynamic scope currently spans the whole `/16`. Shrink it to a bounded block
  (`10.20.100.0/24`) and keep nodes/infra as **static MAC reservations in their tiers**, outside
  the pool. Reservations are honored during PXE, so each node PXE-boots straight onto its tier IP.
- **Addressing:** third octet = tier; hosts from `.11` (`.1–.10` reserved per tier). Workers =
  apprentice quartet `.20.11–.14` (severian/drotte/roche/eata, eata youngest → last) + jonas `.15`;
  drotte/roche also carry the GPUs. API VIP `10.20.254.100`, LB pool `10.20.250.0/24` (existing).
- Full rationale/history lives in `docs/disk-hardware-plan.md`; this file is the terse reference.
