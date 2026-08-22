# Network Segmentation Plan (Calico NetworkPolicy)

Status: **Plan only, informed by real flow data.** Written 2026-08-22, picking up
`docs/security-plan.md` §2.2 ("Network segmentation — the biggest structural gap" — Calico's
fully deployed, including Whisker/Goldmane flow visibility, but zero policies enforced today).
This doc owns the actual design/rollout; §2.2 now just points here.

## Decision

**Calico `NetworkPolicy`/`GlobalNetworkPolicy`, not plain Kubernetes `NetworkPolicy` and not a
service mesh.**

- Calico's already the CNI here — its own policy CRDs are a strictly better fit than plain
  Kubernetes `NetworkPolicy` for this specific job: `GlobalNetworkPolicy` can express a
  cluster-wide baseline (e.g. "every namespace may reach coredns") in one object instead of
  copy-pasting the same rule into every namespace's own policy, and Calico's explicit
  `Allow`/`Deny` actions + tier ordering make "default-deny, then a short list of exceptions"
  the natural shape rather than something assembled indirectly from a pile of additive-only
  `NetworkPolicy` objects.
- **Staged policies are already installed** (confirmed live:
  `stagedglobalnetworkpolicies.crd.projectcalico.org`,
  `stagednetworkpolicies.crd.projectcalico.org`) — this is the actual safe-rollout mechanism:
  a `StagedNetworkPolicy`/`StagedGlobalNetworkPolicy` evaluates traffic and logs what it *would*
  deny (visible in Whisker/Goldmane as `pending_actions`) without ever actually blocking
  anything, so a policy can be watched against real traffic before promoting it to the real
  enforced object. Every policy below goes through staged first.
- **Service mesh (Istio/Linkerd/Cilium mesh mode) was considered and rejected.** It solves a
  different, harder problem — mTLS identity and L7 traffic management across many
  services/teams — at real operational cost (sidecar or ambient-mode injection, cert rotation
  infrastructure, an extra proxy hop in every debugging session). For "stop a compromised app
  from freely reaching everything else" in a single-admin cluster, that's disproportionate
  machinery for the actual goal, and would be one of the largest single additions to the whole
  stack for a problem Calico already solves natively.
- **Baseline shape: default-deny ingress per namespace, plus a short list of cluster-wide
  exceptions** — not a bespoke policy per app from day one. The flow-data review below shows
  the real cross-namespace traffic is dominated by two wide fan-outs (`network` routing
  ingress, `observability` scraping metrics) rather than a large number of one-off app-to-app
  dependencies, so a namespace-level baseline covers almost everything; per-app policies layer
  on top only where something needs tighter rules than its namespace's default.

## Flow-data review (2026-08-22, ~1200 flows, Whisker/Goldmane)

Pulled directly from Goldmane via Whisker's backend API
(`whisker-backend.calico-system.svc:3002/flows`, plain HTTP internally despite the TLS env vars
on the container — those configure the *client* connection to Goldmane, not the listener) and
aggregated by (source namespace, dest namespace). Same-namespace and pod↔internet flows excluded
from the table below (see notes).

### Universal — needed in every namespace
| Traffic | Detail |
|---|---|
| `* → kube-system`, `udp/53` | DNS to coredns. Every single namespace does this (13/13 namespaces observed made this exact call). Must be a cluster-wide allow, not something to gate per-namespace. |

### Wide fan-out — two namespaces reach almost everyone
| Source | Destinations observed | Why |
|---|---|---|
| `network` | `media`, `download`, `home`, `misc`, `observability`, `immich`, `authentik`, `ai` | Envoy Gateway (`envoy-internal`/`envoy-external`) routing HTTPRoute traffic to backend app Services. This is the ingress path — every namespace with an HTTPRoute needs ingress allowed from `network` on its app's port(s). |
| `observability` | `kube-system`, `network`, `media`, `download` (implied), `misc`, `home`, `flux-system`, `authentik`, `cert-manager`, `data`, `database`, `nvidia-gpu-operator`, `immich`, `ai`, `kopiur-system` | Prometheus scraping `ServiceMonitor`/`PodMonitor` targets everywhere, plus `gatus-sidecar` health-checking `network`'s Envoy pods directly. Needs ingress allowed from `observability` on each app's metrics/health port(s). |

### Narrow, specific pairs — not covered by the two rules above
| Flow | Port | Why |
|---|---|---|
| `database → media` | tcp/3306 | `mariadb-operator` (runs in `database`) managing `grimmory-mariadb` (lives in `media`) — the operator pattern: CRD lives with the app, the operator itself is centralized. |
| `database → observability` | tcp/8123 | `clickhouse-operator` reaching the Akvorado ClickHouse instance (`chi-akvorado-clickhouse`, lives in `observability`) — same operator pattern. |
| `misc → network` | tcp/10443 | A one-shot Job (`forgejo-oidc-source-sync`) calling out through `envoy-internal` — almost certainly hitting Authentik's OIDC endpoint by its public hostname rather than a cluster-local Service DNS name. |
| `kube-system → misc`, `kube-system → nvidia-gpu-operator` | tcp/5000 | `spegel`'s pod-to-pod OCI registry mirror — cross-node, shows up as cross-namespace since spegel itself runs in `kube-system`. Cluster-wide by design (every node needs to reach every other node's spegel instance), not really a namespace-scoped dependency at all. |

### Notes on what's excluded from the table
- **Same-namespace traffic** (`download`: 106 flows, `observability`: 70, `media`: 24, etc.) —
  the default-allow case; a namespace-scoped default-deny only touches *ingress from other
  namespaces*, not intra-namespace traffic (app ↔ its own DB pod, sidecars, etc.).
- **Pod → internet** (`download`: 392 flows, dwarfing everything else) — the `*arr` stack +
  qbittorrent doing their actual job (indexer queries, torrent traffic). This is an *egress*
  question, not ingress, and deliberately out of scope for the ingress-focused baseline below —
  worth its own follow-up decision (e.g. does `download`'s egress need any restriction, or is
  unrestricted internet-bound egress fine for that namespace specifically).

## Proposed baseline (staged first, always)

1. ✅ **Cluster-wide allow: DNS** (`stagedglobalnetworkpolicy-dns.yaml`) — staged, watching for
   unexpected `pending_actions` before promoting.
2. ✅ **Cluster-wide allow: ingress from `network`** (`stagedglobalnetworkpolicy-network-ingress.yaml`)
   — staged, deliberately broad on the first pass (`selector: all()`, no per-app port list — an
   over-broad *allow* is harmless on its own, since it's the later default-deny step that
   actually narrows access; per-app port scoping is a refinement once staged data shows what's
   really needed, now easy to check via `whisker.internal.oreillys.io`).
3. ✅ **Cluster-wide allow: ingress from `observability`**
   (`stagedglobalnetworkpolicy-observability-ingress.yaml`) — staged, same broad-first-pass shape
   as step 2 (`selector: all()`, no per-app port list, TCP-only).
4. ✅ **The narrow pairs above**, each as its own small, explicit rule scoped to just that
   source/dest/port (`stagedglobalnetworkpolicy-database-to-media.yaml`,
   `-database-to-observability.yaml`, `-spegel-mirror.yaml`, `-misc-to-network.yaml`). The last two
   needed judgment calls beyond a plain source/dest/port copy from the flow table:
   - **spegel**: `hostPort`-based node-to-node image-mirror traffic, not a real namespace
     dependency (per the note above) — modeled as source-scoped-only (`allow-spegel-mirror`,
     `selector: all()` destination) rather than a narrow pair, since the destination is genuinely
     "whichever pod on that node happens to be pulling an image," not one fixed app.
   - **misc → network**: lower confidence than the others — this is really a symptom of a bigger,
     not-yet-designed question ("who's allowed to reach envoy-internal/envoy-external as a
     destination", since `network` is the whole cluster's ingress point) rather than a normal
     app-to-app pair. Staged so data keeps flowing; **do not promote this one to enforcing without
     first deciding the wider network-namespace-as-destination model** — see Open Questions.
5. ✅ **Allow same-namespace ingress, everywhere** (`components/common/stagednetworkpolicy-same-namespace.yaml`)
   — staged. Found missing via real `pending_actions` data (see Verification below), not planned
   up front: steps 2-3's `selector: all()` GlobalNetworkPolicies claim every endpoint in the
   cluster for ingress-policy purposes, which bypasses Calico's normal fallback to the permissive
   per-namespace `kns.<ns>` Profile - so ordinary same-namespace traffic (app -> its own DB,
   sidecars, etc.) would go from allowed to denied the moment steps 2-3 promote, unless something
   explicitly allows it first. Modeled as a namespaced `StagedNetworkPolicy` (not Global -
   GlobalNetworkPolicy has no "same namespace as the policy" default the way a namespaced one
   does, and Calico has no selector syntax for "same namespace as the destination endpoint")
   added to `components/common`, which every app namespace's `kustomization.yaml` already
   includes - one file instead of ~17 near-duplicates, and new namespaces get it automatically.
6. ✅ **Network boundary: who can reach `network` (and a few other namespaces) from outside the
   cluster** — closes the gap flagged when step 4's `allow-misc-to-network` was drafted, and
   confirmed by real `pending_actions` data (`PRIVATE NETWORK`/`PUBLIC NETWORK` sources). Designed
   narrow, not a blanket "any external traffic" rule, per the same principle as the rest of this
   baseline:
   **Correction (2026-08-22)**: the first pass used `10.20.0.0/16` as a stand-in for "the LAN" -
   wrong. `10.20.0.0/16` is specifically the *servers* VLAN (cluster nodes, NAS, infra tiers, see
   docs/node-inventory.md), not a general client network, and `10.0.0.0/8` would be far too
   broad. Confirmed which VLANs should actually reach these destinations: `10.10.0.0/16`,
   `10.20.0.0/16`, `10.30.0.0/16`, `10.40.0.0/16` (the "trusted VLANs" referenced below).
   `10.60.0.0/16` (IoT/devices) deliberately excluded - undecided whether it needs access at all,
   revisit once that's settled. Any other VLAN currently reaching the cluster only does so because
   upstream network ACLs (OPNsense) haven't been built yet, not because it's actually meant to.
   - `allow-trusted-vlans-to-envoy-internal` — source is the trusted-VLAN list above (deliberately
     broad *here* since "any trusted-VLAN device can reach envoy-internal" is the actual intended
     behavior, not an oversight), destination scoped to envoy-internal's pods specifically (by
     `owning-gateway-name`, not "all of `network`"), ports 10080/10443/10022 (envoy-internal's
     real container ports - confirmed live via its Service `targetPort`s, not the Gateway-level
     80/443/22).
   - `allow-trusted-vlans-to-envoy-external` — split DNS means hostnames on external routes still
     resolve internally to envoy-external's own VIP for trusted-VLAN clients, so that traffic
     never actually leaves for the internet/OPNsense's NAT hop - same trusted-VLAN source list,
     destination scoped to envoy-external, no SSH port (external doesn't expose it).
   - `allow-opnsense-to-envoy-external` — source `10.2.0.1/32` only, not "the whole internet": for
     traffic that *does* come from the actual internet, OPNsense NATs it before it reaches the
     cluster (already established in envoy.yaml's own ClientTrafficPolicy comment), so that's the
     only L3 source Calico will ever actually see for that path.
   - `allow-apiserver-webhooks` — kube-apiserver runs as a static pod (host network) on each
     control-plane node, so its calls to admission/conversion webhooks across many namespaces
     (cert-manager, mariadb-operator, postgres-operator, external-secrets, kopiur-system,
     metrics-server, envoy-gateway, prometheus-operator) all show up as the same external-source
     shape. One rule, source-scoped-only to the 3 real control-plane node IPs (same pattern as
     step 4's spegel rule) instead of ~8 near-duplicate narrow pairs. calico-system's own
     apiserver/webhook traffic isn't included - already handled by tigera-operator's own
     calico-system-tier policies, evaluated before this tier.
   - `allow-trusted-vlans-to-loki` / `-akvorado` / `-fluent-bit` — real observed trusted-VLAN
     devices pushing data in (NAS's Alloy agent to Loki, network gear's NetFlow to Akvorado's
     inlet, network gear's syslog to fluent-bit), each scoped to its specific app + real port,
     same trusted-VLAN source list - notably *not* just `10.20.0.0/16`: the primary switch's own
     management IP is `10.10.0.1` (docs/network-observability-plan.md), a different VLAN
     entirely, so a servers-VLAN-only rule would have missed the actual switch traffic.
7. **Default-deny ingress**, per namespace, once 1-6 are confirmed correct via staged mode —
   this is the step that actually turns "nothing enforced" into "namespace isolation by
   default," and it only goes in after watching real traffic against the staged version of
   everything above and confirming nothing legitimate gets flagged as would-be-denied. Note: this
   isn't a separate "flip a switch" step - promoting steps 1-6 themselves from Staged to real,
   enforcing policies *is* what creates the default-deny effect (see the mechanism in step 5
   above), so all of 1-6 need to go enforcing together, not gradually with gaps between them.
8. **Egress**, as a deliberate separate decision per namespace (not bundled into this ingress
   baseline) — `download`'s internet-bound traffic is the obvious first case to think through.
   **Low priority** — track as a roadmap item, not blocking on the ingress baseline above.

## Verification (2026-08-22)

Queried Goldmane's `/flows` API directly (via a port-forward to the `whisker` Service, same
endpoint the flow-data review above used) for a ~1250-flow sample and checked each flow's
`policies.pending` field - what *would* happen if everything currently staged were promoted to
enforcing. This is the process steps 5-6 depend on: review pending denies, fix real gaps, confirm
clean, then promote.

Found 198 flows with a pending Deny, three categories:
- **The same-namespace gap above (step 5)** - the majority of the 198, e.g. `authentik→authentik:5432`,
  `immich→immich` (several ports), `misc→misc` (forgejo/linkwarden/nebraska), dozens of
  `observability→observability` pairs. Real bug, now fixed by step 5.
- **The `network`-as-destination gap** - `PRIVATE NETWORK`/`PUBLIC NETWORK → network:10080/10443/9443`,
  real LAN/internet client traffic hitting the gateway pods directly, falling through
  `allow-misc-to-network`'s narrow source selector to `EndOfTier: Deny`. Confirmed the open
  question flagged when that rule was drafted; **closed by step 6**.
- **Noise** - `calico-system/curltest*`/`nettest*` entries are ad-hoc debug pods from an earlier
  live-troubleshooting session, not real traffic.

**Step 5 re-checked after merge (2026-08-22)**: filtered to only flows recorded after the fix
went live (the full-history query was misleading - Goldmane computes `pending` at ingestion time
and keeps ~1hr of history, so a single query mixes pre-fix and post-fix snapshots of the same
recurring conversations). `authentik-postgres-2 -> authentik-postgres-1:5432` confirmed:
`pending` now shows `StagedNetworkPolicy allow-same-namespace, action: Allow` instead of
`EndOfTier: Deny`. Zero pending denies across two fresh post-fix samples. Gap closed.

Re-check step 6 the same way once it merges and reconciles, before moving on to step 7.

## Rejected-traffic visibility & alerting

Checked what Calico itself offers for reviewing/being notified about denied traffic (matters
both for troubleshooting a policy that's too tight and for noticing unexpected traffic patterns
— an app quietly trying to phone home somewhere new, for example):

- **Ad-hoc investigation: already works, today.** Every flow — allowed *and* denied — already
  goes through Goldmane with full detail (source/dest, labels, ports, which policy decided it),
  filterable by action. This is the same API the flow-data review above used
  (`whisker-backend.calico-system.svc:3002/flows`). Whisker itself is now exposed at
  `whisker.internal.oreillys.io`, wrapped in SSO — no more port-forwarding to check this.
- **Proactive alerting: not available in open-source Calico.** Checked directly against Felix's
  own Prometheus metrics reference (not just a summary) — `calico_denied_packets` (the metric a
  "deny rate" alert would use) is **Calico Cloud/Enterprise-only**. Open-source Felix exposes
  plenty of internal state (endpoints, policies, iptables, BPF) but nothing for policy denies.
  No free Prometheus metric to alert on here.
- **A real path exists, not yet designed:**
  - **Poll Goldmane's flow API** on a schedule for `action=Deny`, route hits into the existing
    Alertmanager/Slack pipeline. Straightforward, uses the exact API already proven working.
  - **Calico's `Log`-then-`Deny` pattern** — an explicit `Log` rule ahead of a policy's `Deny`
    puts denied packets into the kernel log via iptables' `LOG` target, which fluent-bit already
    ships to Loki. Same shape as the already-proven `SyslogErrorRateHigh` keyword alert from the
    network-observability work — would fit this cluster's existing alerting conventions well,
    but adds a live logging cost to every enforced deny (worth weighing against the poller
    option, which has none).
  - Neither is implemented. Revisit once the ingress baseline (steps 1-5 above) is live enough
    to actually be generating denies worth alerting on.

## Open questions

- Does every app in a fan-out namespace (`media`, `download`, etc.) actually need ingress from
  *all* of `network`'s traffic, or would scoping to specific ports per app (rather than a blanket
  namespace-level allow) be worth the extra policy surface? Leaning toward namespace-level for
  the baseline, app-level as a later tightening pass if it turns out to matter.
- ~~Whether `kube-system → *` (spegel) should be a real per-namespace allow or whether it's
  cleaner to just exempt `kube-system` as a source everywhere, given its cluster-wide-by-design
  nature.~~ Resolved in step 4: modeled as source-scoped-only (`allow-spegel-mirror`, destination
  `selector: all()`), not a full source exemption — still requires port 5000 specifically.
- **New from step 4**: who should be allowed to reach `network` namespace pods (envoy-internal/
  envoy-external) as a *destination*? Every other rule in this plan is about `network` as a
  *source* (steps 2 above). `network` is the cluster's whole ingress point, so its own
  default-deny-ingress (step 5) needs a deliberate answer here, not just the one narrow
  `allow-misc-to-network` rule staged for the forgejo CronJob - e.g. does LAN-external traffic to
  the Gateway VIP even traverse Calico's pod-ingress policy path the same way east-west traffic
  does, or does kube-vip's DNAT put it somewhere policy can't see? Needs research before `network`
  gets a default-deny, not before the rest of the baseline.
