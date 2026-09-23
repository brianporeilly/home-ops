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
| `10.20.40.0/24`  | GPU / accelerator nodes — first host `gpu-typhon` (`.11`, dedicated GPU worker, currently testing/not yet joined); legacy GPU boxes (`wk-drotte`/`wk-roche`) stay tier-20 workers |
| `10.20.50.0/24`  | **Onboard/management NICs on dual-NIC worker boxes** — see "Nodes with a separate mgmt NIC" below. Not a cluster-traffic tier; kubelet must **never** report an address here as its node IP. |
| `10.20.100.0/24` | DHCP dynamic pool — shrink OPNsense scope to here; nodes stay static reservations in tiers |
| `10.21.0.0/16`   | LoadBalancer pool (kube-vip-cloud-provider `cidr-global`); routed via OPNsense static route, deliberately off-link from `10.20.0.0/16` so it's not affected by the ARP/L2-adjacency issue the old, now-removed `10.20.250.0/24` pool had with kube-vip's BGP-only VIPs |
| `10.20.254.0/24` | Cluster VIPs (existing — API `10.20.254.100`) |

## Reserved / infrastructure IPs

| IP | Purpose |
|----|---------|
| 10.20.0.1 | Gateway / router (kube-vip BGP peer) |
| 10.20.254.100 | Kubernetes API VIP (kube-vip) — **existing, keep** |
| 10.21.0.0/16 | LoadBalancer pool (kube-vip-cloud-provider `cidr-global`); requires an OPNsense static route (`10.21.0.0/16` via `10.2.0.2`) |

## LoadBalancer service IPs (`10.21.0.0/16`)

Auto-assigned sequentially by kube-vip-cloud-provider unless otherwise noted (sourced live via
`kubectl get svc -A --field-selector spec.type=LoadBalancer`, captured 2026-08-19). The old
`10.20.250.0/24` pool has been fully retired — nothing uses it, removed from
`cidr-global` entirely (was a sub-range of the node subnet, so kube-vip's BGP-only VIPs weren't
reliably ARP-reachable there; see kube-vip-cloud-provider's `helmrelease.yaml` for the full
rationale).

| IP | Service | Namespace |
|----|---------|-----------|
| 10.21.0.1 | envoy-external (gateway) | network |
| 10.21.0.2 | envoy-internal (gateway) | network |
| 10.21.0.3 | omada-controller | network |
| 10.21.0.4 | fluent-bit | observability |
| 10.21.0.5 | loki | observability |
| 10.21.0.6 | akvorado-inlet-flows | observability |
| 10.21.0.10 | minecraft — **reserved, not currently deployed** (`kube-vip.io/loadbalancerIPs` pin, app disabled in `home/kustomization.yaml`) | home |
| 10.21.0.11 | frigate | home |
| 10.21.0.12 | slskd-soulseek | download |

## Nodes — identity / compute / network

| Hostname | Role | Old name | Chassis | CPU | RAM | IP | NIC |
|----------|------|----------|---------|-----|-----|----|----|
| `cp-gurloes`   | control-plane (etcd) | k8s-test-01   | Dell OptiPlex 7050 | i7-7700 | 16 GB | 10.20.10.11 | 1GbE |
| `cp-malrubius` | control-plane (etcd) | k8s-wk-02     | Dell OptiPlex 7050 | i7-7700 | 16 GB | 10.20.10.12 | 1GbE |
| `cp-palaemon`  | control-plane (etcd) | — (new spare) | Lenovo ThinkCentre M900 Tiny (10MR0047US) | i5-6500T | 16 GB | 10.20.10.13 | 1GbE |
| `wk-severian`  | worker (Ceph SSD OSD)      | k8s-cp-01 | Dell OptiPlex 9020 | i7-4770 (Haswell) | 32 GB | 10.20.20.11 | 10GbE |
| `wk-drotte`    | worker (Ceph HDD+SSD OSD, **GPU**) | k8s-cp-02 | Dell OptiPlex 9020 | i7-4790 (Haswell) | 32 GB | 10.20.20.12 | 10GbE |
| `wk-roche`     | worker (Ceph HDD OSD, **GPU**)     | k8s-cp-03 | Dell OptiPlex 9020 | i7-4790 (Haswell) | 32 GB | 10.20.20.13 | 10GbE |
| `wk-eata`      | worker (Ceph HDD OSD)      | k8s-wk-03 | Dell Precision Tower 3620 | Xeon E3-1270 v5 (Skylake, ECC-capable) | 32 GB | 10.20.20.14 | **1GbE ⚠** |
| `wk-jonas`     | worker (Ceph SSD OSD / compute) | k8s-wk-01 | HP EliteDesk 800 G2 DM (65W) | i5-6500 (Skylake) | 16 GB | 10.20.20.15 | 1GbE |
| `wk-talos`     | worker (compute — Jellyfin transcode, iGPU Quick Sync) | — (new) | Dell OptiPlex 7090 Ultra (UFF) | i5-1145G7 (Tiger Lake) | 8 GB stock — upgrade planned | 10.20.20.16 (planned) | 1GbE |
| `nas-ultan`    | NAS (ZFS)                  | ubuntu-01 | whitebox (ASRock, DMI OEM-blank) | Xeon E3-1230 v3 (Haswell, ECC) | 32 GB (4×8 DDR3-1333, **maxed**) | 10.20.30.11 | 10GbE |
| `gpu-typhon`   | worker (dedicated **GPU** — LLM/compute), testing — not yet joined to cluster | — | ASUS X99-DELUXE II (desktop) | i7-5820K (Haswell-E, 6c/12t) | 8 GB — upgrade planned | 10.20.40.11 | 1GbE |

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
| `wk-talos`     | eth0      | `70:b5:e8:59:ed:5a` | — | — | 1.43.0 |
| `gpu-typhon`   | enp11s0   | `38:d5:47:ad:4f:e8` | — | — | 0801 |
| `nas-ultan`    | enp0s25   | `bc:5f:f4:fd:ec:92` | enp2s0f0 (link down) | `a0:36:9f:e5:70:78` | P1.70 |

## Nodes with a separate mgmt NIC — kubelet `--node-ip` pinning required

Dual-NIC boxes (10GbE-equipped workers) carry **two live addresses**: the onboard 1GbE NIC sits
on the `10.20.50.0/24` mgmt tier, the 10GbE add-in card sits on the real `10.20.20.0/24` data
tier. Both are up and routable, so kubelet's IP auto-detection can pick either one - it must be
pinned explicitly via `KUBELET_KUBEADM_ARGS="--node-ip=<data-IP>"` in
`/var/lib/kubelet/kubeadm-flags.env`, or kubelet may register the node with the **mgmt** IP as
`status.addresses[InternalIP]`. Since hostNetwork pods (Ceph mgr, etc.) inherit that IP as their
own `status.podIP`, a wrong pin/no pin means anything routing to that pod via the Service (e.g.
the `rook-ceph-mgr-dashboard` HTTPRoute) silently breaks even though the pod itself is healthy
and actually listening correctly on the data IP - confirmed live 2026-08-19 on `wk-roche` (see
incident note below).

| Hostname | Data NIC (pin this) | Mgmt NIC (never pin this) |
|----------|----------------------|----------------------------|
| `wk-severian` | `enp1s0f0` → `10.20.20.11` | `eno1` → `10.20.50.11` |
| `wk-drotte`   | `enp5s0f0` → `10.20.20.12` | `eno1` → `10.20.50.12` |
| `wk-roche`    | `eth0` → `10.20.20.13`     | `eth3` → `10.20.50.13` |

**Incident (2026-08-19):** `wk-roche` was reinstalled/rejoined without the `--node-ip` pin (its
`kubeadm-flags.env` had an empty `KUBELET_KUBEADM_ARGS`, unlike its siblings above) - a config
template step got skipped during the reinstall. Kubelet auto-detected the mgmt NIC as its node
IP, which broke the Ceph dashboard route (Service → Endpoint pointed at the mgmt IP, which the
mgr's hostNetwork listener wasn't actually reachable on) while every other symptom looked fine
(pod `3/3 Running`, `ceph health` clean). Also worth noting: `wk-roche` came back with generic
`eth0`/`eth3` interface names instead of the predictable `enoX`/`enpXsXfX` names its siblings
have - possibly the same skipped template, worth checking against a fresh install if it recurs.
**Any future node reinstall/rejoin on a dual-NIC box must explicitly set `--node-ip` to the data
IP** - don't rely on auto-detection.

## Nodes — RAM / DIMMs (upgrade headroom)

CP nodes upgraded 2026-08-19 (cannibalized DIMMs from other machines) to relieve control-plane
`KubeNodeEviction`/`MemoryPressure` — `kube-apiserver` alone was running 2.2-3.1 GB RSS against an
8 GB node with only ~5.1 GB Allocatable, and climbing; see chat history for the full
diagnosis. From `dmidecode -t 16/17` via `toolbox` (not installed on the bare Flatcar host, so
`sudo toolbox bash -c "dnf install -y dmidecode; dmidecode -t 17"`), captured 2026-08-19. "Board
max" is what SMBIOS type-16 reports (= the CPU/platform ceiling on these).

| Hostname | Installed | Slots | Modules | Type / speed | Board max | Headroom |
|----------|-----------|-------|---------|--------------|-----------|----------|
| `cp-gurloes`   | 16 GB | 2 / 4 | 2×8 GB DIMM1+DIMM2 (dual-channel) | DDR4-2400 UDIMM, configured 2400 MT/s | 64 GB | **2 slots free** — cheapest add |
| `cp-malrubius` | 16 GB | 1 / 4 | 1×16 GB DIMM1 (single-channel — DIMM2-4 empty) | DDR4-2400 UDIMM, configured 2400 MT/s | 64 GB | **3 slots free**; adding an 8GB+ stick to DIMM2 would also pick up dual-channel |
| `cp-palaemon`  | 16 GB | 2 / 2 | 2×8 GB SODIMM, ChannelA+ChannelB (dual-channel, mismatched speed ratings: 2400 + 2667, both negotiated down to 2133 MT/s) | DDR4-2133 SODIMM | 32 GB | **0 slots free** — maxed for this DIMM size; reaching the 32 GB board ceiling needs swapping *both* to 16 GB modules |
| `wk-severian`  | 32 GB | 4 / 4 | 4×8 GB | DDR3-1600         | 32 GB | **maxed** — platform ceiling (DDR3) |
| `wk-drotte`    | 32 GB | 4 / 4 | 4×8 GB | DDR3-1600         | 32 GB | **maxed** — platform ceiling (DDR3) |
| `wk-roche`     | 32 GB | 4 / 4 | 4×8 GB | DDR3-1600         | 32 GB | **maxed** — platform ceiling (DDR3) |
| `wk-eata`      | 32 GB | 4 / 4 | 4×8 GB | DDR4-2133         | 64 GB | → 64 GB, but **no free slots** (4×16 swap) |
| `wk-jonas`     | 16 GB | 2 / 2 | 2×8 GB | DDR4-2133 SODIMM  | 32 GB | → 32 GB, but **no free slots** (2×16 swap) |
| `wk-talos`     | 8 GB  | 1 / 2 | 1×8 GB DIMM1 (DIMM2 empty) | DDR4-3200 UDIMM | 64 GB | **1 slot free** — cheapest add is a 2nd 8GB+ stick in DIMM2 (also picks up dual-channel) |
| `gpu-typhon`   | 8 GB  | 1 / 8 | 1×8 GB DIMM_C1 (Corsair, single-channel — DIMM_A1/A2/B1/B2/C2/D1/D2 empty), rated 3000 MT/s but running at 2133 MT/s (BIOS/XMP not configured for it) | DDR4-2133 (configured), 3000 MT/s rated | 512 GB *(dmidecode board figure — see note)*, realistically 64 GB (Intel-spec CPU max) or up to 128 GB per board QVL, unverified | **7 slots free** — quad-channel X99 platform; **planned replacement**, not just an add — a matched quad kit with XMP enabled would pick up real memory bandwidth for GPU workloads |
| `nas-ultan`    | 32 GB | 4 / 4 | 4×8 GB | DDR3-1333         | 32 GB | **maxed** — platform ceiling (DDR3) |

**Takeaways:** (1) the three DDR3 Haswell workers + the NAS are at their hard ceiling — more
worker/ARC RAM there means a board/CPU swap, not DIMMs. (2) Only DDR4 nodes can grow: `wk-eata`
(→64 GB) and `wk-jonas` (→32 GB) via *swaps* (slots full). (3) CP nodes were bumped 8→16 GB each
2026-08-19 (see table above) - `gurloes`/`malrubius` still have free DDR4 UDIMM slots for another
round if 16 GB ever proves tight again; `palaemon` is out of slots and would need a swap to
16 GB SODIMMs to grow further.

## Nodes — storage

| Hostname | OS / boot disk | Ceph OSDs / data disks | block.db | Notes |
|----------|----------------|------------------------|----------|-------|
| `cp-gurloes`   | **Intel DC S3610 200GB (placed 2026-08-15)** — Patriot P210 128GB freed | — | — | tainted NoSchedule |
| `cp-malrubius` | **Intel DC S3610 200GB (placed 2026-08-15)** — Samsung 870 EVO 500GB freed | — | — | tainted NoSchedule |
| `cp-palaemon`  | **Intel DC S3610 200GB (placed 2026-08-15)** — Intel 520 240GB (SSDSC2CW240A3) freed | — | — | tainted NoSchedule; 2.5" bay; **+ Intel SSDPEKKF256G7L 256GB NVMe in M.2 (undocumented spare)** |
| `wk-severian`  | Patriot P210 128GB | **SSD:** Samsung 850 EVO 1TB | — | 2-bay, SATA-only |
| `wk-drotte`    | SanDisk X400 128GB (SD8SB8U) | **HDD:** HGST HUA723020ALA640 2TB · **SSD:** WD Blue WDBNCE0010P 1TB · **GPU:** GTX 745 | HGST colocated | SATA-only; WD Blue **placed** — 3rd SSD OSD, `ceph-blockpool-ssd` back to `size: 3` |
| `wk-roche`     | SanDisk X400 128GB (SD8SB8U) | **HDD:** WD20EARX 2TB · **GPU:** GTX 745 | SATA SSD (pending) | SATA-only; block.db SSD not yet present |
| `wk-eata`      | Patriot P210 128GB | **HDD:** WD20EARX 2TB | SATA SSD (pending) | SATA-only; block.db SSD not yet present; ⚠ **10GbE NIC not detected** (only onboard 1GbE) |
| `wk-jonas`     | Patriot P210 128GB | **SSD:** WD_BLACK SN770M 1TB NVMe | — | MFF, M.2 |
| `wk-talos`     | Micron 2450 NVMe 256GB (M.2, serial `22363B3CD51F`, fw 24500007) | — (compute-only, no OSD) | — | UFF, single M.2 slot — boot/OS disk only |
| `gpu-typhon`   | Samsung SSD 850 PRO 256GB (SATA, serial `S1SUNSAFC59418H`) | — (compute-only, no OSD) | — | desktop tower; **GPU:** GTX 1070 + Tesla P100-PCIE-16GB (confirmed via `nvidia-smi`/`lspci`) |
| `nas-ultan`    | Crucial M4 64GB (boot) | **ZFS (planned):** 5× WD60EFAX 6TB + 1× HGST HUS726060ALE611 6TB (3 mirror vdevs) + 1× WD60EFAX cold spare | — | **disks to be re-laid to plan at teardown.** *Currently* (old cluster): 4× WD60EFAX + 1× HGST in ZFS; WD Blue 1TB SSD = `/data` (Longhorn — reclaim target); X400 128GB = `/var`; 6× iSCSI Longhorn PVCs mounted |

## Notes

- **etcd disks:** 3× Intel DC S3610 200GB (SSDSC2BX200G4R) placed 2026-08-15 (all 3 CP nodes,
  rolling swap — see `disk-hardware-plan.md` §3). Freed: Patriot P210 128GB (gurloes), Samsung
  870 EVO 500GB (malrubius), Intel 520 240GB (palaemon).
- **block.db (roche/eata HDD OSDs):** candidates = Intel Pro 1500 180GB (on hand) + one cascade
  SATA SSD (870 EVO or Intel 520, now freed from the S3610 swap above). drotte's HGST runs
  colocated.
- **Chassis swap of note:** the old control-plane boxes (k8s-cp-01/02/03) became workers; the new
  control plane is the 8GB machines (k8s-wk-02 + k8s-test-01 + a new Lenovo).
- **GPU nodes = `wk-drotte` + `wk-roche`** (old k8s-cp-02 @ `10.20.20.11`, k8s-cp-03 @ `.12`), each
  with an **NVIDIA GTX 745 (Maxwell)** — the *same machines* as two storage workers, not separate
  boxes. Driver: Flatcar `nvidia.service`, pinned 580.105.08 (last Maxwell branch); see
  `gpu-nodes-flatcar-nvidia` memory. These were GPU-bearing **CP nodes** in the old cluster (why
  ollama-on-etcd hurt) → now pure workers, which resolves it. Re-IP `.20.11/.12` → `.20.12/.13`;
  update ansible/SSH + the memory.
- **`gpu-typhon` (10.20.40.11)** — new dedicated GPU worker, first host in the `10.20.40.0/24`
  tier. Named for the two-headed tyrant (Typhon) — apt if it ends up dual-GPU (possible 2nd Tesla
  P100 upgrade, TBD). Specs via `scripts/node-hw-report.sh`, captured 2026-09-21: ASUS X99-DELUXE
  II desktop board (BIOS 0801, AMI, dated 2016-06-28), Intel i7-5820K (Haswell-E, 6c/12t @
  3.30GHz), 8 GB RAM (1×8GB Corsair DIMM_C1, rated 3000 MT/s but running at 2133 MT/s since the
  board isn't configured/XMP'd for it — 7 of 8 slots free, quad-channel X99 platform. `dmidecode`
  reports "Maximum Capacity: 512 GiB" but that's a generic SMBIOS board figure (8 slots × a
  blanket per-slot ceiling), **not** a real achievable limit — Intel's official spec for the
  i7-5820K caps it at **64 GB**, and the X99-DELUXE II's own QVL lists up to 128 GB (8×16GB UDIMM,
  since X99 boards double as Xeon E5 v3 boards) though that's above Intel's validated spec for
  this consumer CPU and unconfirmed for this specific board/CPU pairing. Plan around 64 GB as the
  safe ceiling. **Planned replacement**, not just an add — worth doing given only 8GB today). Boot
  disk: Samsung SSD 850 PRO 256GB (`S1SUNSAFC59418H`). GPU: **NVIDIA GTX 1070 + Tesla
  P100-PCIE-16GB**, both confirmed via `nvidia-smi`/`lspci` (driver 580.105.08, CUDA 13.0) — the
  P100 didn't show up in the first `node-hw-report.sh` pass because it's a compute-only card with
  no display output, so `lspci` classes it as `3D controller` rather than `VGA compatible
  controller`/`Display controller`; the script's grep missed that class (fixed in the script).
  Dual onboard NICs: Intel I218-V (`enp11s0`,
  `38:d5:47:ad:4f:e8`, 1GbE, link up — use this MAC for the DHCP/PXE static reservation) and Intel
  I211 (`eth0`, `38:d5:47:ad:4f:e9`, no link detected). Also carries a Broadcom BCM4360 802.11ac
  wifi adapter, unused for cluster traffic. Running but **not yet joined to the cluster** — still
  in standalone testing.
- **DHCP (OPNsense):** dynamic scope currently spans the whole `/16`. Shrink it to a bounded block
  (`10.20.100.0/24`) and keep nodes/infra as **static MAC reservations in their tiers**, outside
  the pool. Reservations are honored during PXE, so each node PXE-boots straight onto its tier IP.
- **Addressing:** third octet = tier; hosts from `.11` (`.1–.10` reserved per tier). Workers =
  apprentice quartet `.20.11–.14` (severian/drotte/roche/eata, eata youngest → last) + jonas `.15`
  + talos `.16` (planned). drotte/roche also carry the GPUs. API VIP `10.20.254.100`, LB pool
  `10.21.0.0/16` (the old `10.20.250.0/24` pool has been fully retired - see addressing plan above).
- **`wk-talos`** (Dell OptiPlex 7090 UFF, i5-1145G7, service tag `6BJPDF3`) added as a dedicated
  Jellyfin-transcode compute node — Tiger Lake iGPU (Iris Xe / Quick Sync), not a discrete-GPU
  node like drotte/roche, so it's **not** managed by nvidia-gpu-operator. BIOS 1.43.0. Onboard NIC
  is Intel I219-LM (`eth0`, 1GbE, confirmed link at 1000Mb/s) — no 10GbE add-in, no PCIe slot on
  this chassis, and 10GbE isn't worth adding for a transcode-only workload (output bitrate is
  reduced by design; source reads from Ceph/NAS stay well under 1GbE even for 4K HDR). Single M.2
  NVMe (Micron 2450 256GB) as boot/OS disk only — compute node, not a Ceph
  OSD host. RAM: 1×8GB DDR4-3200 UDIMM in DIMM1, DIMM2 empty (64GB board ceiling) — upgrade planned.
  Powers via USB-C/Thunderbolt PD from a display (90W+ required, monitor must be on the
  Thunderbolt input) or the native 90W barrel adapter. Gathered via `scripts/node-hw-report.sh`;
  not yet joined to the cluster (`kubectl get nodes` doesn't show it yet) — IP `10.20.20.16` is
  still just the planned static reservation.
- Full rationale/history lives in `docs/disk-hardware-plan.md`; this file is the terse reference.
