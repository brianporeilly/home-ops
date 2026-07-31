# Cluster Migration Inventory

Old cluster: k3s (Rancher), direct Helm, Longhorn storage
New cluster: k3s (kube-vip), FluxCD/bjw-s app-template, Rook/Ceph storage

Legend:
✅ Deployed, ready — running on new cluster, fully functional
🟡 Deployed, no data — running but waiting on NAS/media/DB migration
🔲 Staged — files exist on main but disabled/commented out
🌿 Branch — app files exist on a feature branch only (PR not opened or WIP)
❓ Needs decision — on old cluster, not yet decided if migrating
💀 Skip — decided not to migrate
⚪ Dead (old) — was scaled to 0 on old cluster

---

## Infrastructure (system-level)

| App | Old | New | Notes |
|-----|-----|-----|-------|
| cert-manager | ✅ | ✅ | All 3 components |
| coredns | ✅ | ✅ | Cluster-default, not managed in repo |
| ingress-nginx | ✅ | ❌ | Replaced by Envoy Gateway (Gateway API) |
| metrics-server | ✅ | ✅ |  |
| kube-vip | ✅ | ✅ | Different config (BGP w/ AS 65001) |
| kube-vip-cloud-provider | ❌ | ✅ | New - LoadBalancer IPs via CIDR |
| metallb | ✅ | ❌ | Replaced by kube-vip cloud provider |
| calico | ✅ | ✅ | Flux-managed (tigera-operator HelmRelease + Installation CRs) |
| oauth2-proxy | ✅ | ❌ |  | No | ❌ Skip - not needed |
| system-upgrade-controller | ✅ | ❌ | K3s managed separately |
| kubernetes-dashboard | ✅ | 💀 | Prefer k9s + phone app |
| GitLab agent/runner | ✅ | 💀 | Not needed |
| longhorn-system | ✅ | ❌ | Replaced by Rook/Ceph |
| reloader | ❌ | ✅ | New - auto-restart pods on config changes |
| snapshot-controller | ❌ | ✅ | New - VolumeSnapshots |
| kured | ❌ | ✅ | New - reboot management |
| ceph-csi-drivers | ❌ | ✅ | New - CSI SA/RBAC for ceph-csi-operator |

---

## Media

| App | Old | New | Data Migration | NAS Dep | Notes |
|-----|-----|-----|---------------|---------|-------|
| audiobookshelf | ✅ | ✅ | None (reads media from NAS) | Yes - media library | Config migrated (PVC) |
| jellyfin | ✅ | ✅ | None (reads media from NAS) | Yes - media library | Config migrated (PVC) |
| jellyseerr | ✅ | ❓ | None (just config) | No | Not started - media requests portal |
| navidrome | ✅ | 💀 | None (reads music from NAS) | Yes - music library | Not using |
| ersatztv | ❌ | 🟡 | None (reads media from NAS) | Yes - media library | New - virtual TV channels, needs NAS |
| tdarr | ✅ | 🔲 | Config only | Yes - media library | On main but not wired in kustomization |
| bazarr | ✅ | ✅ | Config only (small) | Yes - media library | Subtitle management |

---

## Download/Arr Stack

| App | Old | New | Data Migration | NAS Dep | Notes |
|-----|-----|-----|---------------|---------|-------|
| sabnzbd | ✅ | ✅ | Config migrated | Yes - download staging |  |
| sonarr | ✅ | ✅ | Config migrated | Yes - media library |  |
| radarr | ✅ | ✅ | Config migrated | Yes - media library |  |
| prowlarr | ✅ | ✅ | Config migrated | No | Just API keys/indexers |
| recyclarr | ❌ | ✅ | Config migrated | No | New - auto-sync quality profiles |
| nzbget | ✅ | 🔲 | Config only (small) | Yes - download staging | Disabled in favor of sabnzbd |
| readarr | ✅ | 💀 | N/A | N/A | Replaced by grimmory |
| lidarr | ✅ | ✅ | Config only (small) | Yes - music library | Music management |
| qbittorrent | ✅ | ✅ | Config migrated | Yes - download staging | Deployed |
| mylar | ✅ | ⚪ | N/A | N/A | Was scaled to 0 on old cluster |

---

## Home/Automation

| App | Old | New | Data Migration | NAS Dep | Notes |
|-----|-----|-----|---------------|---------|-------|
| home-assistant | ✅ | 🟡 | Old history not imported | No | Running on fresh CNPG (SSD tier); old SQLite recorder history not imported — decide keep/drop |
| esphome | ✅ | ✅ | N/A | No | Config only, merged & enabled (PR #29) |
| mosquitto | ✅ | ⚪ | N/A | N/A | Was 0 replicas on old cluster |
| zwavejs2mqtt | ✅ | ⚪ | N/A | N/A | Was 0 replicas on old cluster |
| home-assistant-influxdb | ✅ | 💀 |  | No | Not needed |
| grocy | ✅ | 🔲 | N/A | No | Staged, commented out |
| frigate | ✅ | 🔲 | **Major** - recordings | Yes - NVR storage | Staged, disabled; needs NAS for recordings |
| changedetection | ✅ | ✅ | Config only (small) | No | URL monitoring |
| paperless-ngx | ✅ | ✅ | Fresh (no data) | No | Deployed; CNPG on SSD tier |
| vaultwarden | ✅ | ✅ | Confirm vault migrated | No | Deployed; verify old vault DB imported |

---

## Other Services

| App | Old | New | Data Migration | NAS Dep | Notes |
|-----|-----|-----|---------------|---------|-------|
| pihole | ✅ | 💀 | Config only (small) | No | Skip - not needed |
| searxng | ✅ | ✅ | Config only | No | Metasearch engine |
| calibre-web | ✅ | ⚪ | N/A | Yes - e-book library | Was 0 replicas (grimmory replaces) |
| octoprint | ✅ | 🌿 | N/A | No | Branch `add-octoprint`, needs node + USB config |
| magic-mirror | ✅ | ⚪ | N/A | No | Was 0 replicas |
| minecraft | ✅ | 🌿 | N/A | No | Branch `add-minecraft`, already configured |
| statping | ✅ | 💀 | N/A | No | Replaced by gatus |
| timemachine | ✅ | ⚪ | N/A | No | Was 0 replicas |
| bastion | ✅ | ⚪ | N/A | No | Was 0 replicas |
| omada-controller | ❌ | ✅ | None (fresh start) | No | New - network management |

---

## New Apps (no old counterpart)

| App | Status | Notes |
|-----|--------|-------|
| immich | ✅ | Fully deployed (server + ML + valkey + CNPG) |
| grimmory | ✅ | Fully deployed (app + MariaDB) |
| gatus-sidecar | ✅ | Fully deployed, replaces statping |
| prometheus/grafana/loki | ✅ | Full observability stack deployed |
| fluent-bit | ✅ | Log shipping to Loki |
| smartctl-exporter | ✅ | SMART disk monitoring |
| rook-ceph | ✅ | Storage (replaces Longhorn) |
| ceph-csi-drivers | ✅ | CSI SA/RBAC for ceph-csi-operator |
| envoy-gateway | ✅ | Ingress (replaces nginx-ingress) |
| postgres-operator (CNPG) | ✅ | Database operator |
| mariadb-operator | ✅ | Database operator |

---

## Migration Priority

### ✅ Done — deployed and working
- All infrastructure (cert-manager, metrics-server, kube-vip, kube-vip-cloud-provider, reloader, snapshot-controller, kured, calico)
- All observability (prometheus/grafana/loki, fluent-bit, smartctl-exporter, gatus-sidecar)
- All storage (rook-ceph, rook-ceph-cluster, ceph-csi-drivers) — **device-class tiered**:
  DBs on `ceph-block-ssd` (SSD OSDs), bulk/media on `ceph-block` (HDD). See
  `ceph-device-class-tiering` memory + `disk-hardware-plan.md`.
- All networking (envoy-gateway, certificates, omada-controller)
- All databases (CNPG ×5, mariadb-operator) — all on the SSD tier
- **esphome** (merged & enabled)
- **immich**, **grimmory**, **paperless-ngx**, **vaultwarden**, **qbittorrent**
- **home-assistant** (fresh CNPG; old history not imported)
- **arr stack**: sabnzbd, sonarr, radarr, prowlarr, recyclarr, lidarr, bazarr
- **changedetection**, **searxng**
- **jellyfin**, **audiobookshelf**, **ersatztv** (all need NAS media to be useful)

### 🟡 Deployed but needs data decision
- **home-assistant** — running on fresh CNPG; old SQLite recorder history not imported (decide keep/drop)
- **vaultwarden** — deployed; confirm the old vault DB was imported

### 🌿 Branch ready, needs PR + merge
- **octoprint** — `add-octoprint`, needs node + USB config
- **minecraft** — `add-minecraft`, ready to PR

### 🔲 Staged (disabled but mergeable)
- **grocy** — commented out, just uncomment
- **tdarr** — on main but not wired into kustomization
- **frigate** — commented out, needs NAS
- **nzbget** — commented out in favor of sabnzbd

### ❓ Needs decision
- **jellyseerr** - media requests portal

### 💀 Skip
- readarr → replaced by grimmory
- navidrome → not using
- oauth2-proxy → not needed
- pihole → not needed
- influxdb → not needed
- statping → replaced by gatus

### ⚪ Dead on old cluster (was 0 replicas)
- mosquitto, zwavejs2mqtt, calibre-web, magic-mirror, mylar, timemachine, bastion

---

## Data Migration Notes

**DB data decisions (apps deployed, data import outstanding):**
- home-assistant: running on fresh CNPG (SSD); old SQLite recorder history not imported — decide keep/drop
- vaultwarden: deployed; confirm the old vault DB was imported
- paperless-ngx: deployed fresh (no prior data to migrate)

All CNPG/MariaDB databases now live on the `ceph-block-ssd` tier. Backups are not yet in
place — see `backup-dr-plan.md` for the target architecture.

**Config-only (migrated or straightforward):**
- sonarr, radarr, prowlarr, jellyseerr
- changedetection, searxng
- lidarr, bazarr

**Media (NAS reads only, no migration needed):**
- jellyfin, audiobookshelf, navidrome, tdarr, ersatztv — just repoint to NAS share

**Requires NAS storage (not wired yet):**
- frigate recordings (large, needs NAS NFS)
- paperless documents (needs NAS or large PVC)
- media library (already on old NAS, not connected to new cluster)
- download staging (sabnzbd, qbittorrent — currently using Ceph PVCs, not ideal)

## NAS Dependencies

NAS (Synology) is connected to the old cluster but not wired to the new cluster. NFS CSI driver (`csi-driver-nfs`) is configured in `kube-system` but disabled in kustomization. Everything relying on NAS-mounted media is non-functional until the NAS is online in the new cluster.

Apps blocked by NAS:
- jellyfin, audiobookshelf, ersatztv, tdarr — all media apps need media library
- frigate (if enabled) — needs NVR storage
- paperless-ngx (if migrated) — document storage
- qbittorrent (if enabled) — download staging ideally NAS-backed

Apps NOT blocked by NAS:
- sabnzbd, sonarr, radarr, prowlarr, recyclarr — work in degraded mode (no media folder access but arr stack config functions)
- home-assistant, grocy, changedetection, vaultwarden — standalone
- gatus, grafana, prometheus — standalone
