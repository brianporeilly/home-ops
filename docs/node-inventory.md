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
| `cp-gurloes`   | control-plane (etcd) | k8s-test-01   | Dell OptiPlex 7050 | i7-7700 (assumed) | 8 GB  | 10.20.10.11 | 1GbE |
| `cp-malrubius` | control-plane (etcd) | k8s-wk-02     | Dell OptiPlex 7050 | i7-7700 | 8 GB  | 10.20.10.12 | 1GbE |
| `cp-palaemon`  | control-plane (etcd) | — (new spare) | Lenovo (M.2 + 2.5" bay) | i5-6500T | 8 GB  | 10.20.10.13 | 1GbE |
| `wk-severian`  | worker (Ceph SSD OSD)      | k8s-cp-01 |  |  | 32 GB | 10.20.20.11 | 10GbE |
| `wk-drotte`    | worker (Ceph HDD+SSD OSD, **GPU**) | k8s-cp-02 |  |  | 32 GB | 10.20.20.12 | 10GbE |
| `wk-roche`     | worker (Ceph HDD OSD, **GPU**)     | k8s-cp-03 |  |  | 32 GB | 10.20.20.13 | 10GbE |
| `wk-eata`      | worker (Ceph HDD OSD)      | k8s-wk-03 |  |  | 32 GB | 10.20.20.14 | 10GbE |
| `wk-jonas`     | worker (Ceph SSD OSD / compute) | k8s-wk-01 | MFF desktop |  | 16 GB | 10.20.20.15 | 1GbE |
| `nas-ultan`    | NAS (ZFS)                  | ubuntu-01 |  |  |  | 10.20.30.11 | 10GbE |

## Nodes — storage

| Hostname | OS / boot disk | Ceph OSDs / data disks | block.db | Notes |
|----------|----------------|------------------------|----------|-------|
| `cp-gurloes`   | Toshiba THNSN5256GPUK 256GB NVMe → **S3610 200GB** | — | — | tainted NoSchedule; S3610 pending |
| `cp-malrubius` | Samsung 870 EVO 500GB → **S3610 200GB** | — | — | tainted NoSchedule; S3610 pending |
| `cp-palaemon`  | Intel 520 240GB → **S3610 200GB** (etcd) | — | — | tainted NoSchedule; 2.5" bay; S3610 pending |
| `wk-severian`  | Patriot P210 128GB | **SSD:** Samsung 850 EVO 1TB | — | 2-bay, SATA-only |
| `wk-drotte`    | SanDisk X400 128GB | **HDD:** HGST HUA723020ALA640 2TB · **SSD:** WD Blue WDBNCE0010P 1TB · **GPU:** GTX 745 | HGST colocated | SATA-only; WD Blue **pending** (old-NAS Longhorn) |
| `wk-roche`     | SanDisk X400 128GB | **HDD:** WD20EARX 2TB · **GPU:** GTX 745 | SATA SSD (pending) | SATA-only |
| `wk-eata`      | Patriot P210 128GB | **HDD:** WD20EARX 2TB | SATA SSD (pending) | SATA-only; holds the spare 10GbE NIC |
| `wk-jonas`     | Patriot P210 128GB | **SSD:** WD_BLACK SN770M 1TB NVMe | — | MFF, M.2 |
| `nas-ultan`    | Crucial M4 64GB (boot) | **ZFS:** 5× WD60EFAX 6TB + 1× HGST HUS726060ALE611 6TB (3 mirror vdevs) + 1× WD60EFAX cold spare | — | still runs old-cluster Longhorn until teardown |

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
