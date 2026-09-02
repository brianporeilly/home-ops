# Egress Segmentation Plan (Calico NetworkPolicy)

Status: **Roadmap - staging phase started 2026-08-31.** Follow-on to
`docs/network-policy-plan.md`, whose step 8 deferred egress as "a deliberate
separate decision per namespace... low priority, track as a roadmap item."
The ingress baseline (default-deny ingress everywhere) has been enforcing
since 2026-08-23 with no further incidents since the DNS outage was fixed -
enough soak time to start the same staged-rollout process for egress.

Same methodology as the ingress plan throughout: **staged policies only in
this doc's first pass** (`StagedGlobalNetworkPolicy`/`StagedNetworkPolicy`,
`stagedAction: Set`) - these evaluate every flow and record what *would*
happen, visible in Whisker/Goldmane as `pending_actions`, without blocking
anything. Nothing here goes enforcing until there's been a representative
watch window and a review pass, same as ingress steps 1-6 before step 7's
promotion.

## Why egress is a different shape than ingress

Ingress default-deny answers "who can reach this pod." Egress default-deny
answers "what can this pod reach" - and the two aren't symmetric in this
cluster for one big structural reason found while gathering the flow data
below:

**Most of Ceph's own traffic is already outside Calico's reach.** `rook-ceph`
runs with `network.provider: host` (confirmed via `ceph cluster` CR) - `mon`,
`mgr`, `mds`, `osd`, `exporter`, and `crashcollector` pods all run
`hostNetwork: true` (confirmed via `kubectl -n rook-ceph get pods -o
custom-columns=...HOSTNETWORK`). Calico's per-workload enforcement only
applies to pods with their own Calico-managed pod IP - a host-networked pod's
traffic shares the node's network namespace and never passes through Calico's
per-workload iptables/eBPF rules at all (no `HostEndpoint` protection is
configured here). **Practical effect: an egress default-deny in this cluster
will never need - and can never enforce - any rule for Ceph's own
mon/mgr/mds/osd/exporter/crashcollector daemon traffic.** Only the small
number of real (non-hostNetwork) pods in `rook-ceph` - `rook-ceph-operator`,
`ceph-csi-controller-manager`, the two CSI `ctrlplugin` pods, and
`rook-ceph-osd-prepare` Jobs - are actually in scope, and per the flow data
below their only observed need is apiserver access (already covered
universally, see below).

## Flow-data review (2026-08-31, ~1180 flows, Whisker/Goldmane)

Same source as the ingress review: `whisker.calico-system.svc:8081/whisker-backend/flows?page_size=3000`,
aggregated by source namespace this time (egress is about what leaves a
namespace, not what enters one). Same-namespace flows excluded (not an
egress-policy concern - same-namespace default-deny needs its own allow, same
as ingress step 5, but the pairs themselves aren't interesting to review).

### Universal - needed in every namespace, or egress default-deny can't even be staged usefully
| Flow | Detail |
|---|---|
| `* → kube-system`, `udp+tcp/53` | DNS. Exact mirror of the ingress plan's step 1 - every namespace needs this to resolve anything at all. |
| `* → PRIVATE NETWORK 10.20.10.{11,12,13}/32, tcp/6443` | kube-apiserver. Runs as a static pod on each control-plane node (host network), so it shows up as an external "PRIVATE NETWORK" destination, not a normal Service ClusterIP, the same way the ingress plan found apiserver *source* traffic showing up externally for the webhook-ingress rule. **Every single namespace sampled** made this call (controllers/operators watching resources, leader election, health checks, `kubernetes.default.svc` clients) - this is as universal as DNS. |
| same-namespace | Same gap as ingress step 5, for the same reason: a `selector: all()` Egress policy going enforcing ends the permissive `kns.<ns>` Profile fallback for egress too, the moment the first one promotes. |

### Wide fan-out - two namespaces are heavy egress sources, mirroring their ingress role
| Source | Destinations observed | Why |
|---|---|---|
| `network` | `media`, `home`, `download`, `misc`, `observability`, `authentik`, `immich`, `ai` | Envoy Gateway routing HTTPRoute traffic *to* backend Services - the exact same paths the ingress plan's `allow-network-ingress` already allows from the destination side, just observed here from the source side. |
| `observability` | `kube-system`, `calico-system`, `misc`, `network`, `authentik`, `home`, `flux-system`, `data`, `immich`, `media`, `cert-manager`, `kopiur-system` (cross-namespace, via ServiceMonitor/PodMonitor scraping) **plus** a large `PRIVATE NETWORK` slice - `tcp/10259` (kube-scheduler), `tcp/10257` (kube-controller-manager), `tcp/2381` (etcd), `tcp/10250`/`tcp/10249` (kubelet), `tcp/9100` (node-exporter), `udp/161` (SNMP - network-observability's snmp_exporter polling switches, see `docs/network-observability-plan.md`), `tcp/9283` (ceph-mgr, host-network per above) | Same wide-fan-out role as the ingress plan found for `observability → *`, but the *destination* side now includes real cluster pods **and** the control-plane/node-level daemons that run host-network and would otherwise show as unreachable "external" targets under a naive default-deny. |

### Narrow / needs a decision - not staged in this first pass
| Flow | Notes |
|---|---|
| `download → PUBLIC NETWORK`, mostly high-port UDP | The actual point of `download` existing - indexer HTTPS calls (`tcp/443`) plus qBittorrent's DHT/peer traffic (hundreds of distinct ephemeral UDP ports in one 15-second sample, one per swarm peer). Staged below as a deliberately broad, **namespace-wide** `0.0.0.0/0` allow for this first pass - matches the ingress plan's own reasoning for `allow-opnsense-to-envoy-external` (this namespace's whole job is public internet exposure/access, so a source-IP-style narrow allowlist doesn't fit the actual need). **Decided (2026-08-31): narrow this per-app once staged, not left broad long-term** - `download` bundles several apps (`sonarr`/`radarr`/`prowlarr`/`sabnzbd`/qBittorrent) with genuinely different internet-access needs (the arr stack talks to specific indexer/metadata APIs over HTTPS; only qBittorrent needs the wide-open high-port UDP swarm traffic), and lumping them under one namespace-wide allow hides that qBittorrent having broad egress doesn't mean sonarr should too. Once this has soaked (or even once it's just applied and staged data exists), splitting `allow-download-egress-internet` into one rule per app - or per pod selector within the namespace - should be straightforward using the same pending_actions review process as everything else here. Tracked as a concrete next step below, not just a someday-maybe. |
| `flux-system → PUBLIC NETWORK`, `tcp/22`+`tcp/443` | `source-controller` fetching the `GitRepository` (SSH + HTTPS) and any `OCIRepository`. **Staged below despite being "narrow"** - unlike everything else deferred to a follow-up, breaking this would break the entire GitOps pipeline that would be needed to *fix* a bad egress promotion, the same class of self-inflicted-deadlock risk the calico Kustomization's dependency comment already warns about. Not worth leaving as an open question. |
| `home → PRIVATE NETWORK`, `tcp/6053` (ESPHome native API), `tcp/80` (frigate → cameras), `icmp`, `udp/1900` (SSDP) | Real LAN-device traffic (ESP32 sensors, IP cameras) - but which VLAN(s) these devices actually live on isn't confirmed yet, and IoT devices specifically were the one trusted-VLAN entry the ingress plan deliberately left out (`10.60.0.0/16`, "undecided whether it needs access at all"). Not staging a guess - needs the same VLAN-by-VLAN confirmation the ingress plan did before landing `allow-trusted-vlans-to-envoy-internal`. |
| `authentik`/`misc`/`media`/`immich` → `PUBLIC NETWORK tcp/443`, small counts (2-4 each) | Plausible explanations (blueprint/version checks, forgejo's OIDC source sync, metadata lookups) but not confirmed against a specific outbound call the way every staged rule above is. Left for a follow-up review once there's more data - low volume, low urgency. |
| `rook-ceph` (non-hostNetwork pods) | Per the structural note above, only `rook-ceph-operator`/`ceph-csi-controller-manager`/CSI `ctrlplugin`/`osd-prepare` are actually in Calico's scope, and the only need seen for them is apiserver access - already covered by the universal rule. Nothing pool-specific needed here. |

## Staged so far (2026-08-31)

All `StagedGlobalNetworkPolicy`/`StagedNetworkPolicy`, `stagedAction: Set` -
none enforcing, none blocking anything. Files in
`kubernetes/apps/kube-system/calico/policies/` unless noted:

1. `stagedglobalnetworkpolicy-dns-egress.yaml` - universal DNS.
2. `stagedglobalnetworkpolicy-apiserver-egress.yaml` - universal kube-apiserver access, `nets:`-scoped to the 3 real control-plane IPs (same pattern as `allow-apiserver-webhooks`).
3. `kubernetes/components/common/stagednetworkpolicy-same-namespace-egress.yaml` - universal same-namespace, mirrors `allow-same-namespace` but `Egress`. Kept as a **separate object** from the existing (already-enforcing) `allow-same-namespace` rather than adding an `egress:` block to it - that policy is live today, so touching it directly would start enforcing egress immediately with zero observation window, exactly the mistake the "staged first, always" rule exists to prevent.
4. `stagedglobalnetworkpolicy-network-egress.yaml` - broad `network → all()`, TCP. Deliberately broad first pass, same reasoning as `allow-network-ingress`.
5. `stagedglobalnetworkpolicy-observability-egress-cluster.yaml` - broad `observability → all()`, TCP, for ServiceMonitor/PodMonitor scraping.
6. `stagedglobalnetworkpolicy-observability-egress-private-network.yaml` - `observability → nets: [10.10.0.0/16, 10.20.0.0/16]` (narrower than the full trusted-VLAN list - matches only what's actually observed, same reasoning as `allow-trusted-vlans-to-loki`), TCP + UDP/161, for node/control-plane metrics scraping and SNMP polling.
7. `stagedglobalnetworkpolicy-download-egress-internet.yaml` - `download → nets: 0.0.0.0/0`, TCP + UDP. Broad by design (see table above).
8. `stagedglobalnetworkpolicy-flux-egress-git.yaml` - `flux-system → nets: 0.0.0.0/0`, `tcp/22` + `tcp/443`. Staged now rather than deferred, per the table above.

## Round 2: reviewing real pending-diff data (2026-08-31)

Once the staged policies above had been live for a few hours, checked whether the Grafana "Network" dashboard's pending-diff table actually showed the divergence they should have caused. It didn't - `job=calico-pending-diff-log` had been silent since 2026-08-23. Root cause turned out to be a real bug in `calico-deny-log-shipper`'s `resolve()` function: it only checked each policy-list entry's own `kind` for whether a staged policy was involved, but an `EndOfTier` decision carries that information in a nested `trigger.kind` field instead - so exactly the case this table exists to catch (a broad staged policy claiming the tier and newly denying a flow) was silently dropped every time. Fixed separately (see git history for `calico-deny-log-shipper`'s `helmrelease.yaml`), and validated directly against live flow data before merging: the old logic shipped 0 diffs, the fixed logic shipped 76 real ones from a single sample.

With the fix live, reviewed ~254 accumulated pending-diff hits (34 distinct flow patterns) and categorized them:

**Wide fixes covering several distinct flow patterns at once** (found via real data, not the original flow review):
- **Every CNPG postgres cluster → `rook-ceph-rgw`, `tcp/80`** - 7 different clusters (authentik, immich, home-assistant, paperless, linkwarden, forgejo, nebraska) hitting the identical gap: `rook-ceph-rgw` runs `hostNetwork: true`, so WAL-archive/backup traffic to it shows as an external destination. One rule, scoped by the `cnpg.io/cluster` label (present on every CNPG instance) rather than a per-namespace list. Destination scoped to `10.20.0.0/16` (the servers VLAN), not RGW's current node IP - RGW is a plain Deployment, not pinned to a node, so an IP-scoped rule would silently break on reschedule.
- **`rook-ceph`'s own operator/CSI pods → Ceph's mon/OSD ports directly** - a real gap the original flow review missed entirely (it assumed rook-ceph's only non-hostNetwork-pod need was apiserver access). `rook-ceph-operator`, both CSI `ctrlplugin` variants, and `osd-prepare` all need `tcp/3300` (mon) and the `6800:6810` OSD port range.
- **`10.2.0.1/32` (OPNsense) added to `allow-observability-egress-private-network`** - fixes `crowdsec → tcp/8080` (confirmed live: crowdsec talks to OPNsense's bouncer API directly) and SNMP polling of OPNsense (`docs/network-observability-plan.md` confirms OPNsense is SNMP-polled, not just the switches) in one edit, since the existing TCP block already has no port restriction.

**Per-app internet access, confirmed real via live data** (supersedes this doc's earlier "small/unconfirmed PUBLIC:443" deferral for these four - now confirmed, not guessed):
- `changedetection`'s `sockpuppetbrowser` sidecar → `0.0.0.0/0`, broad (its whole job is rendering arbitrary watched URLs, same shape as `download`).
- `jellyfin`/`jellyseerr` (`media`) → `0.0.0.0/0` on `tcp/443`.
- `immich-server` → `0.0.0.0/0` on `tcp/443`.
- `authentik-worker` → `0.0.0.0/0` on `tcp/443` (almost certainly authentik's own GeoIP database update job).
- `alertmanager`/`grafana` (`observability`) → `0.0.0.0/0` on `tcp/443`. Alertmanager's case is confirmed important, not just plausible: it's the Slack webhook receiver every alert in this cluster routes through.

**Egress mirrors of existing ingress-only operator pairs** - `allow-database-to-media` and `allow-database-to-observability` have been enforcing (ingress) since the original network-policy-plan.md rollout, but nothing ever granted the matching egress:
- `mariadb-operator` (`database`) → `grimmory-mariadb` (`media`), `tcp/3306`.
- `altinity-clickhouse-operator` (`database`) → `chi-akvorado-clickhouse` (`observability`), `tcp/8123`.

**Still unresolved, deliberately not staged** - lower confidence or needs input this review couldn't supply:
- `network/envoy-internal → PRIVATE NETWORK:7000` - checked every port omada-controller's HelmRelease/Service actually expose (8043/8088/8843/29810-29817/27001-27002) - none are 7000, and nothing else in the repo listens there either. Unidentified.
- `observability/akvorado-orchestrator → PRIVATE NETWORK:8443` - only 2 hits, unconfirmed whether this is OPNsense-related (would already be fixed by the `10.2.0.1/32` addition above if so) or something else.
- `kube-system/spegel → external-secrets-webhook:5000` - only 1 hit, an odd pairing (spegel's job is node-to-node image mirroring) - possibly a one-off artifact rather than a real recurring pattern.

## Round 3: verifying round 2 and reviewing what's left (2026-09-01)

Confirmed round 2's fixes actually worked - compared pending-diff data from before/after the merge (23:27:41 UTC) rather than assuming: all 24 targeted patterns disappeared. One (`ceph.rbd.csi.ceph.com-ctrlplugin`'s traffic) took until 23:38:15 to fully stop showing up - about 11 minutes of per-node Felix/Goldmane propagation lag, the same already-documented category, not a new problem.

Two more clean fixes found in the post-merge data, same "egress mirror of an enforcing ingress-only rule" shape as round 2's database pairs - missed by the earlier reviews, not deferred on purpose:
- **`changedetection → llama-cpp:8080`** - the single largest gap in the whole dataset (133 hits in ~4.5h). Mirrors `allow-changedetection-to-llama-cpp`, which has been enforcing (ingress) since the original network-policy-plan.md rollout.
- **`postgres-operator → every CNPG instance's :8000 API`** (authentik/home-assistant/paperless/immich/linkwarden/nebraska/forgejo, ~62 hits combined) - mirrors `allow-postgres-operator-webhook`, same source-scoped-only shape as `allow-apiserver-webhooks`/`allow-spegel-mirror`.

One more real, continuous need, not previously staged:
- **`metrics-server → kubelet, tcp/10250`** - kubelet runs host-network like the apiserver, so this shows as `PRIVATE NETWORK`. 181 hits, clearly ongoing (metrics-server's whole job), not deferred.

**Investigated and deliberately NOT staged**: `media/jellyfin-exporter → PRIVATE NETWORK:8096`. Checked the actual config (`--jellyfin.address=http://jellyfin.media.svc.cluster.local:8096`, a plain ClusterIP DNS call, same namespace, neither pod `hostNetwork`, jellyfin's Service is plain `ClusterIP` not LoadBalancer) - this should resolve as a normal pod-to-pod flow. Only 3 hits, real gap already covered by `allow-same-namespace-egress` regardless of the odd classification. Concluded this is a one-off Calico/Goldmane endpoint-attribution artifact (the same "freshly-spawned pod" classification noise already documented elsewhere in this project), not a real policy gap - staging a `nets:`-based rule for it would mask the real (already-covered) need rather than fix anything.

## Round 4: live pending-diff review (2026-09-01)

Reviewed `job="calico-pending-diff-log"` in Loki directly (6h window, ~1700
lines) rather than waiting for the next doc pass - found several
high-volume patterns none of the earlier flow reviews had caught:

**Staged this round, confirmed real:**
- **`media/navidrome → PUBLIC:443`** (45 hits/6h) - the Last.fm agent
  configured in #832 (artist images/bio) plus other metadata providers.
  Landed after the original flow review, so never staged.
- **`misc/nebraska → PUBLIC:443`** (12 hits/6h) - nebraska's `syncer`
  mirrors Flatcar OS update payloads from the upstream release feed
  (`app/helmrelease.yaml`). Confirmed via source, not just volume.
- **`kube-system/kured → observability/prometheus:9090`** (98 hits/6h) -
  kured checking for active alerts before draining/rebooting a node.
- **`observability/gatus-sidecar → PUBLIC:53 tcp`** (286 hits/6h) - gatus's
  own `connectivity.checker` in `app/resources/config.yaml` hardcodes
  `1.1.1.1:53` as its internet-reachability probe. Scoped to that single
  IP rather than `0.0.0.0/0` - confirmed as one fixed target, not
  arbitrary-host traffic like the other internet-egress rules.

**`network/omada-controller → PUBLIC:443`** (290 hits/6h, the single
largest new pattern found). Traced to a real destination via `kubectl
exec` + `ss -tnp` inside the pod: `34.239.223.202` (AWS us-east-1,
`ec2-34-239-223-202.compute-1.amazonaws.com`) - a TP-Link/Omada-cloud-
hosted endpoint. Server logs confirm it's `LocalFirmwareUpgradeMonitor`'s
periodic "Target firmware check" plus a CA-certificate update check, both
on a 5-minute interval - legitimate TP-Link functionality (checking for
controlled/staged firmware updates for managed devices), but genuine
phone-home to TP-Link's cloud, not something the controller's own local
config requested. **Decided (2026-09-01): allow it** - the dest IP is
AWS-hosted infrastructure, not a stable TP-Link-owned range, so
`allow-omada-controller-egress-internet` is staged broad
(`nets: 0.0.0.0/0`, `tcp/443`), same shape as the other
unknown-destination internet-egress rules, rather than IP-pinned.

## What's deliberately NOT staged yet

- `home`'s LAN-device egress (ESPHome/frigate/SSDP) - needs VLAN confirmation first (same open item as the original review - confirmed as real, recurring traffic via round 2/3's data, but the VLAN-scope question is unchanged).
- The three round-2 "still unresolved" items (`envoy-internal:7000`, `akvorado-orchestrator:8443`, the single `spegel` hit).
- `misc/forgejo-oidc-source-sync → network/envoy-internal:10443` - recurs every CronJob run. Matches the same "misc → network" shape the *ingress* plan generalized into `allow-cluster-to-network-https` rather than a narrow pair - worth the same treatment for egress, not staged yet.
- Small/low-volume items seen in round 3's data needing more samples before a call: `home-assistant → PUBLIC:443`/`udp:80` (new ports on the already-deferred LAN item), `authentik-server → PUBLIC:443` (2 hits), `home/microbin`, `media/podfetch` (1 hit each).
- Any narrowing of the two broad `network`/`observability` cluster-wide egress allows down to specific ports per destination - same "open question" the ingress plan left for its own `network`/`observability` ingress rules; revisit together once there's real usage data either way.
- The actual default-deny-egress effect itself - **not a separate policy to write**. Exactly like ingress step 7: once every `selector: all()` Egress-type policy above is promoted from staged to enforcing, the permissive per-namespace `kns.<ns>` Profile fallback ends for egress on every pod simultaneously, and that *is* default-deny. No explicit "deny all" object needed or wanted. When that promotion happens, it must land as one atomic change for the same reason ingress step 7 had to - see `docs/incidents/2026-08-23-dns-outage.md` before attempting it, and re-read network-policy-plan.md's step 7 correction about the two Kustomizations not being atomic *by construction*.

## Next steps

1. ~~Land the round-3 staged files, let `calico-policies` reconcile.~~ Done, confirmed live 2026-09-01T04:11.
2. Land the round-4 staged files (navidrome/nebraska/kured/gatus/omada-controller), let `calico-policies` reconcile.
3. Keep watching the Grafana "Network" dashboard's pending-diff table - confirm round 4's fixes clear, watch for anything new.
4. Resolve the remaining unresolved items and `home`'s VLAN scope with the same rigor as everything else here - real data, not guesses.
5. Split `allow-download-egress-internet` into per-app rules (per-pod-selector, same namespace) once staged data shows each app's real destination/port shape. Namespace-wide egress for `download` is a first-pass placeholder, not the intended end state.
6. Only then: promote everything to enforcing in one atomic change, learning from the ingress rollout's one real incident.
