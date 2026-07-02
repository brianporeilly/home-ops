# Cluster Migration Inventory

Old cluster: k3s (Rancher), direct Helm, Longhorn storage
New cluster: k3s (kube-vip), FluxCD/bjw-s app-template, Rook/Ceph storage

Legend: ✅ Deployed | 🔲 Configured but disabled | ❌ Not migrated | 💀 Scaled to 0 (likely dead)

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
| calico | ✅ | ✅ | Installed differently (Calico operator, not in repo) |
| oauth2-proxy | ✅ | ❌ |  | No | ❌ Skip - not needed |
| system-upgrade-controller | ✅ | ❌ | K3s managed separately |
| kubernetes-dashboard | ✅ | ❌ | **Needs decision** - do we still use this? |
| GitLab agent/runner | ✅ | ❌ | **Needs decision** - still using GitLab CI? |
| longhorn-system | ✅ | ❌ | Replaced by Rook/Ceph |
| reloader | ❌ | ✅ | New - auto-restart pods on config changes |
| snapshot-controller | ❌ | ✅ | New - VolumeSnapshots |
| kured | ❌ | ✅ | New - reboot management |

---

## Media

| App | Old | New | Data Migration | NAS Dep | Notes |
|-----|-----|-----|---------------|---------|-------|
| audiobookshelf | ✅ | ✅ | None (reads media from NAS) | Yes - media library | Config migrated (PVC) |
| jellyfin | ✅ | ✅ | None (reads media from NAS) | Yes - media library | Config migrated (PVC) |
| jellyseerr | ✅ | ❌ | None (just config) | No | **Needs decision** - media requests portal |
| navidrome | ✅ | ❌ | None (reads music from NAS) | Yes - music library | ❌ Skip - not using |
| ersatztv | ❌ | ✅ | None (reads media from NAS) | Yes - media library | New - virtual TV channels |
| tdarr | ✅ | 🔲 | Config only | Yes - media library | Disabled for now, maybe later |
| bazarr | ✅ | ❌ | Config only (small) | Yes - media library | **Needs decision** - subtitle management |

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
| readarr | ✅ | ❌ | N/A | N/A | ❌ Skip - not needed (grimmory replaces) |
| lidarr | ✅ | ❌ | Config only (small) | Yes - music library | **Needs decision** - music management |
| qbittorrent | ✅ | ❌ | Config + torrents | Yes - download staging | ✅ Migrate - torrent downloads needed |
| mylar | ✅ | 💀 | N/A | N/A | Scaled to 0; comics aggregator |

---

## Home/Automation

| App | Old | New | Data Migration | NAS Dep | Notes |
|-----|-----|-----|---------------|---------|-------|
| home-assistant | ✅ | ✅ | **Major** - DB + config | No | InfluxDB check needed - verify if HA still uses it |
| esphome | ✅ | 🔲 | N/A | No | Config only, disabled for now |
| mosquitto | ✅ | 💀 | N/A | N/A | MQTT broker, was 0 replicas |
| zwavejs2mqtt | ✅ | 💀 | N/A | N/A | Z-Wave, was 0 replicas |
| home-assistant-influxdb | ✅ | ❌ |  | No | ❌ Skip - not needed |
| grocy | ✅ | 🔲 | N/A | No | Not using, just uncomment later if needed |
| frigate | ✅ | 🔲 | **Major** - recordings | Yes - NVR storage | Configured in new, disabled; needs NAS for recordings |
| changedetection | ✅ | ❌ | Config only (small) | No | **Needs decision** - still used? |
| paperless-ngx | ✅ | ❌ | Clean cutover (no data) | No | ✅ Migrate - document management |
| vaultwarden | ✅ | ❌ | **Major** - vault DB | No | ✅ Migrate - password manager |

---

## Other Services

| App | Old | New | Data Migration | NAS Dep | Notes |
|-----|-----|-----|---------------|---------|-------|
| pihole | ✅ | ❌ | Config only | No | ❌ Skip |
| searxng | ✅ | ❌ | Config only | No | **Needs decision** - private search engine |
| calibre-web | ✅ | 💀 | N/A | Yes - e-book library | Was 0 replicas |
| octoprint | ✅ | 💀 | N/A | No | Was 0 replicas; 3D printer UI |
| magic-mirror | ✅ | 💀 | N/A | No | Was 0 replicas |
| minecraft | ✅ | 💀 | N/A | No | Was 0 replicas |
| statping | ✅ | 💀 | N/A | No | 0 replicas; replaced by gatus |
| timemachine | ✅ | 💀 | N/A | No | Was 0 replicas; Time Machine backup |
| bastion | ✅ | 💀 | N/A | No | Was 0 replicas; SSH jump box |
| pihole | ✅ | ❌ | Config only (small) | No | **Needs decision** - DNS/DHCP? |
| omada-controller | ❌ | ✅ | None (fresh start) | No | New - network management |

---

## New Apps (no old counterpart)

| App | Notes |
|-----|-------|
| immich | Photo library replacement |
| grimmory | e-book reader/library (replaces readarr + calibre-web?) |
| gatus-sidecar | Status monitoring (replaces statping) |
| prometheus/grafana/loki | Unified observability stack |
| fluent-bit | Log shipping |
| smartctl-exporter | SMART disk monitoring |
| rook-ceph | Storage (replaces Longhorn) |
| envoy-gateway | Ingress (replaces nginx-ingress) |
| postgres-operator (CNPG) | Database operator |
| mariadb-operator | Database operator |

---

## Migration Priority

### Tier 1: Already Migrated ✅
No action needed — these are running in the new cluster with config migrated.

### Tier 2: Migrate Now (before old cluster decommission)
- **qbittorrent** - config + torrent state, needs download staging NAS
- **paperless-ngx** - clean cutover, no data migration
- **vaultwarden** - DB migration (SQLite dump/restore)

### Tier 3: Stub Apps (create config but leave disabled)
- **esphome** - config only, disabled
- **octoprint** - config only, disabled
- **minecraft** - config only, disabled

### Tier 4: Nice-to-Have (low effort, uncomment when ready)
- **grocy** - already configured, just uncomment
- **tdarr** - already configured, just uncomment (maybe later)
- **changedetection** - config only, small
- **searxng** - config only, small
- **jellyseerr** - config only, small
- **lidarr** - config only, uses existing media
- **bazarr** - subtitle management

### Tier 5: Skip ❌
- readarr → grimmory replaces
- navidrome → not using
- oauth2-proxy → not needed
- pihole → not needed
- influxdb → check HA, likely skip
- All Tier 5 (0 replicas): esphome** (stubbed), mosquitto, zwavejs2mqtt, calibre-web, octoprint** (stubbed), magic-mirror, minecraft** (stubbed), mylar, statping, timemachine, bastion

---

## Data Migration Notes

**Requires DB migration:**
- home-assistant: SQLite → PostgreSQL (CNPG)
- paperless-ngx: PostgreSQL dump/restore
- vaultwarden: SQLite dump/restore

**Config-only (small):**
- sonarr, radarr, lidarr, readarr, prowlarr, bazarr, jellyseerr
- changedetection, searxng, pihole

**Media (NAS reads only, no migration needed):**
- jellyfin, audiobookshelf, navidrome, tdarr, ersatztv — just repoint to NAS share

**Requires NAS storage:**
- frigate recordings (large, needs NAS NFS)
- paperless documents (needs NAS or large PVC)
- media library (already on NAS)
- backup destinations (all databases)

## NAS Dependencies

Currently no NAS is wired up (NFS CSI driver configured but disabled). Everything relying on NAS-mounted media is non-functional until the NAS is online or media is temporarily hosted in Ceph.

Apps blocked by NAS:
- jellyfin, audiobookshelf, ersatztv, tdarr — all media apps
- frigate (if enabled)
- paperless-ngx (if migrated)

Apps NOT blocked by NAS:
- sabnzbd, sonarr, radarr, prowlarr, recyclarr — work in degraded mode (no media folder access but config/arr stack functions)
- home-assistant, grocy, changedetection, vaultwarden — standalone
- gatus, grafana, prometheus — standalone
