# Cluster Migration Inventory

Status: updated 2026-08-14. **Old cluster is now powered off** — vaultwarden's vault DB import
is confirmed restored. The NAS media-file copy is **still in progress** (not yet complete,
looking good so far) — the old cluster going down ahead of that finishing is a change from this
doc's earlier stated plan, noted here rather than smoothed over. The old NAS box was wiped and
rebuilt as `nas-ultan` on the new cluster's network (see `node-inventory.md` /
`disk-hardware-plan.md`).

Since the previous update: `csi-driver-nfs` went from staged-unused to actively used
(frigate, forgejo); forgejo shipped (Postgres + nfs-csi-driver repo/LFS storage), survived
three bootstrap bugs, and moved from `home` to `misc`; soularr (lidarr↔slskd bridge) shipped;
the Kopia-based backup system (`kopiur`) went from draft to **live on 29 apps** with
**restore-on-rebuild and off-site (B2) backups both now also live** (see New Apps table +
Backlog); vaultwarden's DB import completed; copyparty is live and tested; old cluster
decommissioned (media copy still finishing). See Backlog for what's still open.

Old cluster: k3s (Rancher), direct Helm, Longhorn storage (backed by iSCSI PVCs off the old
NAS box).
New cluster: **vanilla Kubernetes via `kubeadm`** (stacked etcd as static pods on the 3
control-plane nodes — **not** k3s, despite this doc previously saying so), FluxCD/bjw-s
app-template, Rook/Ceph storage. See `backup-dr-plan.md` for the cluster-facts callout this
was cross-checked against.

NAS: whitebox ZFS box (`nas-ultan`, was `ubuntu-01` on the old cluster) — **not** a Synology,
correcting an earlier version of this doc. Now rebuilt to the final planned layout (3 mirror
vdevs + cold spare) per `disk-hardware-plan.md` §1.

Legend:
✅ Deployed, ready — running on new cluster, fully functional
🟡 Deployed, no data — running but waiting on NAS/media/DB migration
🔲 Staged — files exist on main but disabled/commented out
🌱 Planned — no code in repo yet, backlog only
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
| oauth2-proxy | ✅ | ❌ | Skip - not needed |
| system-upgrade-controller | ✅ | ❌ | K3s-specific; not applicable to kubeadm |
| kubernetes-dashboard | ✅ | 💀 | Prefer k9s + phone app |
| GitLab agent/runner | ✅ | 💀 | Not needed |
| longhorn-system | ✅ | ❌ | Replaced by Rook/Ceph |
| reloader | ❌ | ✅ | New - auto-restart pods on config changes |
| snapshot-controller | ❌ | ✅ | New - VolumeSnapshots |
| kured | ❌ | ✅ | New - reboot management |
| ceph-csi-drivers | ❌ | ✅ | New - CSI SA/RBAC for ceph-csi-operator |
| csi-driver-nfs | ❌ | ✅ | Enabled (`nfs-slow` StorageClass, dynamic PVCs at `10.20.30.11:/nfs-pvc`). Media/download apps still use static NFS mounts (see note below) — this is for apps that want Kubernetes to own per-PVC lifecycle instead: frigate (recordings) and forgejo (repo/LFS) both use it now. |

---

## Media

| App | Old | New | Data Migration | NAS Dep | Notes |
|-----|-----|-----|---------------|---------|-------|
| audiobookshelf | ✅ | 🟡 | Config migrated | Yes - media library | NFS mount wired (static, `10.20.30.11:/media/audiobooks`); app is functional, media files still being copied onto the new NAS |
| jellyfin | ✅ | 🟡 | Config migrated | Yes - media library | NFS mount wired (static, `10.20.30.11:/media`); same as above — waiting on media copy, not plumbing |
| jellyseerr | ✅ | ✅ | None (just config) | No | Shipped (PR #596), internal-only |
| navidrome | ✅ | ✅ | None (reads music from NAS) | Yes - music library | NFS mount wired (`/media/music`, read-only); shipped on `feat/egress-policy-round3` |
| ersatztv | ❌ | 🟡 | None (reads media from NAS) | Yes - media library | NFS mount wired (same export as jellyfin); waiting on media copy |
| tdarr | ✅ | 🔲 | Config only | Yes - media library | On main but still not wired into `media/kustomization.yaml` |
| bazarr | ✅ | ✅ | Config only (small) | Yes - media library | NFS mount wired; subtitle management, not blocked on media presence |
| podfetch | ❌ | ✅ | N/A | Yes - podcasts export | New - podcast app, NFS mount wired (`/media/podcasts`) |
| tube-archivist | ❌ | ✅ | N/A | Yes - youtube export | New - NFS mount wired (`/media/youtube`) + Ceph for cache/ES/redis |
| grimmory | ❌ | ✅ | N/A | Yes - comics/ebooks export | New (replaces readarr); NFS mounts for `/books` and `/ebooks` |

---

## Download/Arr Stack

| App | Old | New | Data Migration | NAS Dep | Notes |
|-----|-----|-----|---------------|---------|-------|
| sabnzbd | ✅ | ✅ | Config migrated | Yes - download staging | NFS mount wired (`/media/downloads/usenet`); config stays on `ceph-block` |
| sonarr | ✅ | ✅ | Config migrated | Yes - media library | NFS mount wired (whole export, for hardlink import to work) |
| radarr | ✅ | ✅ | Config migrated | Yes - media library | NFS mount wired |
| prowlarr | ✅ | ✅ | Config migrated | No | Just API keys/indexers |
| recyclarr | ❌ | ✅ | Config migrated | No | New - auto-sync quality profiles |
| configarr | ❌ | ✅ | N/A | No | New - arr config sync |
| arr-notifications | ❌ | ✅ | N/A | No | New - notification relay for the arr stack |
| nzbget | ✅ | 💀 | N/A | N/A | Fully removed from repo (was staged/disabled, now deleted — PR #397), superseded by sabnzbd |
| readarr | ✅ | 💀 | N/A | N/A | Replaced by grimmory |
| lidarr | ✅ | ✅ | Config only (small) | Yes - music library | NFS mount wired |
| qbittorrent | ✅ | ✅ | Config migrated | Yes - download staging | NFS mount wired (`/media/downloads/torrents`) |
| qui / qui-bootstrap | ❌ | ✅ | N/A | No | New - qbittorrent UI + bootstrap sync |
| slskd | ❌ | ✅ | N/A | No | New - Soulseek client |
| lazylibrarian | ❌ | ✅ | N/A | Yes - ebook library | New |
| mylar | ✅ | ⚪ | N/A | N/A | Was scaled to 0 on old cluster |

---

## Home/Automation

| App | Old | New | Data Migration | NAS Dep | Notes |
|-----|-----|-----|---------------|---------|-------|
| home-assistant | ✅ | ✅ | Old SQLite recorder history **dropped** (decided) | No | Running on fresh CNPG (SSD tier); fully done |
| esphome | ✅ | ✅ | N/A | No | Config only, merged & enabled |
| mosquitto | ✅ | ⚪ | N/A | N/A | Was 0 replicas on old cluster |
| zwavejs2mqtt | ✅ | ⚪ | N/A | N/A | Was 0 replicas on old cluster |
| home-assistant-influxdb | ✅ | 💀 |  | No | Not needed |
| grocy | ✅ | 🔲 | N/A | No | Merged to main, commented out in `home/kustomization.yaml` |
| frigate | ✅ | ✅ | **Major** - recordings | Yes - NVR storage | Enabled; recordings PVC on `csi-driver-nfs` (`nfs-slow`), not `ceph-block` — deliberately moved off Ceph (large, write-heavy, not worth replicating). |
| octoprint | ✅ | 🔲 | N/A | No | Merged to main, commented out (needs nodeSelector + USB device path); not a live branch |
| minecraft | ✅ | 🔲 | N/A | No | Merged to main, commented out; ready to enable when wanted |
| microbin | ❌ | ✅ | N/A | No | New - paste/share bin |
| changedetection | ✅ | ✅ | Config only (small) | No | URL monitoring |
| paperless-ngx | ✅ | ✅ | Fresh (no data) | Yes - document storage | CNPG on SSD tier; NFS mount wired (`/paperless`) |
| vaultwarden | ✅ | ✅ | Old vault DB import **done** | No | Deployed, running, restored from the old vault DB |

---

## Other Services

| App | Old | New | Data Migration | NAS Dep | Notes |
|-----|-----|-----|---------------|---------|-------|
| pihole | ✅ | 💀 | Config only (small) | No | Skip - not needed |
| searxng | ✅ | ✅ | Config only | No | Metasearch engine |
| calibre-web | ✅ | ⚪ | N/A | Yes - e-book library | Was 0 replicas (grimmory replaces) |
| octoprint | — | — | — | — | See Home/Automation |
| magic-mirror | ✅ | ⚪ | N/A | No | Was 0 replicas |
| statping | ✅ | 💀 | N/A | No | Replaced by gatus |
| timemachine | ✅ | ⚪ | N/A | N/A | Was 0 replicas |
| bastion | ✅ | ⚪ | N/A | N/A | Was 0 replicas |
| omada-controller | ❌ | ✅ | None (fresh start) | No | Network management |
| echo | ❌ | ✅ | N/A | No | New |
| atuin | ❌ | ✅ | N/A | No | New - shell history sync |
| copyparty | ❌ | ✅ | N/A | No | Live and tested |
| linkwarden | ❌ | ✅ | N/A | No | New - bookmark manager |
| maddy | ❌ | ✅ | N/A | No | New - in-cluster SMTP relay (see `maddy-smtp-relay` memory) |
| nebraska | ❌ | ✅ | N/A | No | New |
| thelounge | ❌ | ✅ | N/A | No | New - IRC client |
| tuwunel | ❌ | ✅ | N/A | No | New |
| llama-cpp | ❌ | ✅ | N/A | No | New; replaced ollama (removed 2026-08-16). Declarative model management, no `kubectl exec`. Confirmed working on the GTX 745 (Phi-4-mini Q4_K_M, ~5.8 tok/s). |

---

## New Apps (no old counterpart)

| App | Status | Notes |
|-----|--------|-------|
| immich | ✅ | Fully deployed (server + ML + valkey + CNPG) |
| grimmory | ✅ | Fully deployed (app + MariaDB) — see Media table |
| gatus-sidecar | ✅ | Fully deployed, replaces statping |
| prometheus/grafana/loki | ✅ | Full observability stack deployed |
| fluent-bit | ✅ | Log shipping to Loki |
| smartctl-exporter | ✅ | SMART disk monitoring |
| snmp-exporter | ✅ | Network device SNMP metrics |
| akvorado | ✅ | NetFlow analyzer (Redpanda + ClickHouse backed) |
| kromgo | ✅ | New |
| kubernetes-event-exporter | ✅ | New |
| rook-ceph | ✅ | Storage (replaces Longhorn) |
| ceph-csi-drivers | ✅ | CSI SA/RBAC for ceph-csi-operator |
| envoy-gateway | ✅ | Ingress (replaces nginx-ingress) |
| postgres-operator (CNPG) | ✅ | Database operator |
| mariadb-operator | ✅ | Database operator |
| clickhouse | ✅ | Backs Akvorado |
| redpanda | ✅ | Backs Akvorado (Kafka-compatible bus) |
| nvidia-gpu-operator | ✅ | GPU driver/operand management for `wk-drotte`/`wk-roche` |
| **forgejo** | ✅ | Postgres-backed git forge in `misc` (moved from `home`). Repo/LFS on `csi-driver-nfs` (`nfs-slow`), app state on `ceph-block`. HTTPS + SSH clone, both via `envoy-internal` (HTTPRoute + TCPRoute — see `network/envoy-gateway/config/envoy.yaml`'s `ssh` listener), no dedicated kube-vip LB IP for SSH. Outbound mail via maddy. Survived 3 bootstrap-Job bugs (wrong exec args, missing `INSTALL_LOCK`, not idempotent against Flux's hourly reconcile) — all fixed, see git history on `kubernetes/apps/misc/forgejo/`. |
| **soularr** | ✅ | New — bridges lidarr and slskd (watches lidarr's wanted list, searches/downloads via slskd). `SLSKD_API_KEY` was left as an empty placeholder since slskd runs with `SLSKD_NO_AUTH: true` — confirm that's still true, or fill in a real key. Also confirm the secret got `sops --encrypt`'d and the `[Search Settings]`/`[Release Settings]` defaults in `config.ini` match your preferences — none of that was verified after merge. |
| **kopiur** | ✅ | Kopia-native backup operator for non-DB PVC data (the `backup-dr-plan.md` L2 tier — settled in Kopia's favor over Volsync). Live: shared `ClusterRepository` (NFS to the NAS, under `/backups/kopiur`) + read-only web UI, 29 apps wired via a reusable `SnapshotPolicy`/`SnapshotSchedule` component, hourly schedule. **Restore-on-rebuild also live** — all 22 backed-up apps wired to the `Restore` CSI populator, individually migrated and verified. **Off-site to B2 also live** (own repo + the separate RGW-sourced DB/etcd backups, two buckets). |

---

## NFS wiring note (supersedes old "NAS Dependencies" section)

Every app that needs the media library mounts it directly via bjw-s app-template's native
`type: nfs` persistence — a static NFS mount straight to `10.20.30.11`, **not** the
`csi-driver-nfs` CSI driver (that's a separate, now-also-live path — see below). This landed
across several recent PRs (#396–#398 and earlier `nfs-media-mounts` / `audiobookshelf-nfs-pilot`
/ `downloads-path-alignment` work): jellyfin, audiobookshelf, ersatztv, sonarr, radarr, lidarr,
bazarr, qbittorrent, sabnzbd, paperless-ngx, grimmory, podfetch, tube-archivist all have their
NFS mounts wired and working.

**Media copy is complete** — all apps above are ✅.

**Genuinely not wired yet:**
- **tdarr** — files exist but isn't in `media/kustomization.yaml`, separate from NAS readiness.

**csi-driver-nfs is live**, not just staged: frigate's recordings and forgejo's repo/LFS data
both use it (`nfs-slow` StorageClass, dynamic per-PVC subdirectories under `10.20.30.11:/nfs-pvc`,
quota'd at the parent dataset). Distinct from the static-mount pattern above — this is for data
where Kubernetes should own the PVC lifecycle rather than pointing at a hand-managed export.

---

## Migration Priority

### ✅ Done — deployed and working
- All infrastructure (cert-manager, metrics-server, kube-vip, kube-vip-cloud-provider, reloader, snapshot-controller, kured, calico)
- All observability (prometheus/grafana/loki, fluent-bit, smartctl-exporter, snmp-exporter, akvorado, kromgo, gatus-sidecar)
- All storage (rook-ceph, rook-ceph-cluster, ceph-csi-drivers) — **device-class tiered**:
  DBs on `ceph-block-ssd` (SSD OSDs), bulk/media on `ceph-block` (HDD). See
  `ceph-device-class-tiering` memory + `disk-hardware-plan.md`.
- All networking (envoy-gateway, certificates, omada-controller)
- All databases (CNPG ×5+, mariadb-operator, clickhouse) — DBs on the SSD tier
- **esphome**, **home-assistant** (old recorder history dropped by decision)
- **immich**, **grimmory**, **paperless-ngx**, **qbittorrent**, **jellyseerr**
- **arr stack**: sabnzbd, sonarr, radarr, prowlarr, recyclarr, configarr, arr-notifications, lidarr, bazarr, qui, slskd, lazylibrarian
- **changedetection**, **searxng**
- **NAS itself** — rebuilt to the final planned ZFS layout, live and serving NFS (`10.20.30.11`)
- **NFS wiring** — static mounts done for every app that needs them except tdarr (see note above);
  `csi-driver-nfs` live and in use by frigate + forgejo
- **frigate** — enabled, recordings on `csi-driver-nfs`
- **forgejo** — deployed in `misc`, Postgres + `csi-driver-nfs` for repo/LFS
- **soularr** — deployed, bridges lidarr/slskd (verify placeholder credentials, see New Apps table)
- **vaultwarden** — old vault DB restored into the new CNPG instance
- **copyparty** — live and tested
- **bazarr, sonarr, radarr** — config-only, not blocked on media presence
- Misc new apps: echo, atuin, linkwarden, maddy, nebraska, thelounge, tuwunel, microbin, podfetch, tube-archivist, llama-cpp

### 🟡 Deployed but needs data
- **jellyfin, audiobookshelf, ersatztv** — NFS mounts done, media files still copying onto NAS

### 🔲 Staged (disabled but mergeable)
- **grocy** — commented out, just uncomment
- **tdarr** — on main but not wired into `media/kustomization.yaml`
- **octoprint** — commented out, needs node + USB config
- **minecraft** — commented out, uncomment when wanted

### 💀 Skip
- readarr → replaced by grimmory
- oauth2-proxy → not needed
- pihole → not needed
- influxdb → not needed
- statping → replaced by gatus
- nzbget → replaced by sabnzbd (fully removed from repo, not just disabled)

### ⚪ Dead on old cluster (was 0 replicas)
- mosquitto, zwavejs2mqtt, calibre-web, magic-mirror, mylar, timemachine, bastion

---

## Data Migration Notes

**DB data decisions:**
- home-assistant: fresh CNPG (SSD); old SQLite recorder history **dropped** by decision — done
- vaultwarden: deployed, old vault DB **restored** — done
- paperless-ngx: deployed fresh (no prior data to migrate)

All CNPG/MariaDB databases now live on the `ceph-block-ssd` tier. Backups: see
`backup-dr-plan.md` for current status (Barman/mariadb-native backups → RGW → NAS → B2 off-site,
all done).

**Config-only (migrated or straightforward):**
- sonarr, radarr, prowlarr
- changedetection, searxng
- lidarr, bazarr

**Media (NAS reads, mounts wired, data copy in progress):**
- jellyfin, audiobookshelf, ersatztv, tdarr(pending kustomization wiring)

**NFS-wired via csi-driver-nfs (not static mounts):**
- frigate recordings, forgejo repo/LFS — both done

---

## Old cluster status

**Decommissioned — powered off**, per direct confirmation, even though the NAS media-file copy
is not yet finished (still in progress, no issues reported so far). This is ahead of what this
doc's earlier version said the plan was ("kept alive until... copy verified complete") — noted
as a fact, not resolved into a tidier story. All data was backed up off the old cluster and the
old NAS box was wiped and rebuilt as the new cluster's `nas-ultan` before shutdown.

---

## Backlog / Not yet started

**Done since the last update:**
- **kopiur backup system** — deployed, not just a draft PR. One shared `ClusterRepository`
  (`nas-backups`, inline NFS to `10.20.30.11:/backups`) + a read-only web UI on
  `kopiur.internal.oreillys.io`, reusable `SnapshotPolicy`/`SnapshotSchedule` component
  (`kubernetes/components/kopiur/backup/`, `${APP}`/`${PVC}` substituted via Flux
  `postBuild.substitute`). Rolled out in two batches (High tier: immich, minecraft, linkwarden,
  grocy, forgejo, copyparty, grimmory; Medium tier: 20 more apps across download/media/home/misc/
  network) plus vaultwarden/home-assistant from the original proving-ground wave — **29 apps
  total**, hourly schedule. See `backup-dr-plan.md` L2 for the full writeup and the gotchas hit
  along the way (RBD `snapshotPolicy` CSI default, cross-namespace `credentialProjection`,
  privileged-mover namespace opt-in, non-1000-UID movers needing `root + DAC_OVERRIDE`).

**Done since the last update:**
- **kopiur → auto-restore-on-rebuild** — `Restore` CRD wired as a CSI volume populator
  (`persistence.<name>.dataSourceRef` → `Restore`) across **all 22 apps** wired into kopiur
  backups. Each migrated individually (PVC deleted, restore verified — real data + correct
  ownership, not just "pod is Running") rather than as a decoupled batch, after an early mistake
  (#474) showed that committing `dataSourceRef` ahead of the actual PVC migration blocks *every*
  future Helm update to that app, not just the restore path. See PRs #472–474, #480, #482–485.
  Found and fixed two real bugs along the way: bazarr's Kustomization had never once reconciled
  (Flux-substitute vs. a pre-existing `${VAR}` shell script, #481), and immich hit the DB/disk
  folder-integrity mismatch its own code comment already anticipated (fixed with immich's
  documented remedy). A rolling control-plane reinstall broke the BGP VIP mid-migration; verified
  nothing was actually damaged once the cluster stabilized.

**Done since the last update:**
- **Off-site (B2) backups** — two independent legs, live and each confirmed with a real sync:
  kopiur's own repo mirrors to a `kopiur-backups` bucket via `RepositoryReplication`
  (`kubernetes/apps/kopiur-system/kopiur/repository/replication.yaml`); the RGW-sourced DB/etcd
  backups get a second `rclone sync` leg in `rgw-nas-sync` to a separate `ceph-rgw-backups`
  bucket. Deliberately split into two buckets with separately-scoped B2 Application Keys rather
  than nested under one bucket. Along the way: moved kopiur's NAS repo into its own
  `/backups/kopiur` subdirectory (was sitting at the NAS export root, nested with
  `rgw-nas-sync`'s own directory) and confirmed the flat/no-directories structure B2 shows for
  kopiur's blobs is expected (kopia only shards into subdirectories on filesystem backends, not
  object stores). See `backup-dr-plan.md` §2 L3 for the full writeup.

**Resolved (moot, not fixed):**
- **grimmory-bookdrop's missing backup coverage** — root cause never got investigated because the
  premise changed: bookdrop moved from a `ceph-block` PVC to an NFS mount
  (`10.20.30.11:/media/unsorted/bookdrop`), so it can't be given to LazyLibrarian to write into
  from a different pod/namespace (RWO PVCs only attach to one pod). It's no longer a PVC at all,
  so it's not kopiur's SnapshotPolicy to cover - whatever backup story the NAS has for its own
  export tree applies here now, same as any other NFS-mounted media path.

**Not started:**
- **blackbox_exporter** — Prometheus-native ICMP/TCP probes (NAS ping + NFS port 2049, maybe Omada
  AP ICMP) to get graphable RTT/packet-loss history via Grafana/Alertmanager, distinct from Gatus's
  existing up/down HTTP checks. Scope narrow — don't duplicate what Gatus already covers.
- **maddy inbound email for paperless intake** — cache incoming mail for paperless to
  IMAP-consume without connecting paperless to a real mailbox. Confirmed residential ISP blocks
  inbound port 25, so the public-MX design needs rethinking (dedicated secondary mailbox vs.
  Cloudflare Email Routing → Worker → paperless API). User was going to research further; no
  design decided yet.
- **Scrape OPNsense's CrowdSec plugin metrics** — the in-cluster `crowdsec` agent
  (`observability/crowdsec`) already exposes Prometheus metrics on :6060, scraped via
  `ServiceMonitor`. The CrowdSec instance the os-crowdsec plugin runs on OPNsense itself (LAPI at
  `10.2.0.1:8080`) wraps the same binary, so it likely exposes the same `/metrics` endpoint —
  unconfirmed whether it's enabled and what it's bound to (possibly `127.0.0.1`-only by default,
  and the plugin may regenerate its config on sync, same class of gotcha as other device configs
  in this repo). If reachable, wiring it in is the same `ScrapeConfig` static-target pattern
  already used for the NAS exporters (`kube-prometheus-stack/app/nas-scrapeconfig.yaml`).
- **Authentik as identity provider / SSO for HTTPRoutes** — full IdP (not just an auth proxy
  sidecar; a different shape than the already-decided-against `oauth2-proxy` in the infra table
  above), fronting Envoy Gateway via `SecurityPolicy`/`ExtAuthz` or per-route forward-auth. Main
  use case: apps with no auth at all (or weak/shared-password auth) currently exposed via
  `envoy-internal`/`envoy-external` HTTPRoutes — e.g. kopia web UI, gatus, various dashboards —
  would get a real login wall without each app needing its own user system. Secondary uses:
  centralized MFA, single login across apps that do have their own auth, and an extra layer in
  front of anything internet-facing via `envoy-external`. No design work done yet — needs an
  inventory of which current HTTPRoutes are unauthenticated/weakly-authenticated before deciding
  scope, and a look at how much operational weight a full IdP adds (its own DB, its own SSO
  outage becomes everything's outage) versus the narrower oauth2-proxy shape already passed on.
