# Network Segmentation Plan (Calico NetworkPolicy)

Status: **Done.** Written 2026-08-22, picking up `docs/security-plan.md` §2.2 ("Network
segmentation — the biggest structural gap" — Calico's fully deployed, including
Whisker/Goldmane flow visibility, but zero policies enforced at the time). Every staged policy
below was promoted to enforcing on 2026-08-23 (`feat(calico): step 7 - promote every staged
policy to enforcing`, PR #666) - confirmed live via `kubectl get networkpolicy.projectcalico.org
-A` / `globalnetworkpolicy.projectcalico.org` (default-deny + `allow-same-namespace` in every
namespace, 16 `GlobalNetworkPolicy` cluster-wide exceptions). That promotion was non-atomic
across the two Flux Kustomizations carrying it and caused a real ~39-minute DNS outage - see
`docs/incidents/2026-08-23-dns-outage.md` for the RCA and `fix(calico): remove bogus dependsOn`
(PR #677) for the structural fix.

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

1. ✅ **Cluster-wide allow: DNS** (`globalnetworkpolicy-dns.yaml`) — watched for unexpected
   `pending_actions` before promoting (see Verification).
2. ✅ **Cluster-wide allow: ingress from `network`** (`globalnetworkpolicy-network-ingress.yaml`)
   — deliberately broad on the first pass (`selector: all()`, no per-app port list — an
   over-broad *allow* is harmless on its own, since it's the later default-deny step that
   actually narrows access; per-app port scoping is a refinement once staged data shows what's
   really needed, now easy to check via `whisker.internal.oreillys.io`).
3. ✅ **Cluster-wide allow: ingress from `observability`**
   (`globalnetworkpolicy-observability-ingress.yaml`) — same broad-first-pass shape
   as step 2 (`selector: all()`, no per-app port list, TCP-only).
4. ✅ **The narrow pairs above**, each as its own small, explicit rule scoped to just that
   source/dest/port (`globalnetworkpolicy-database-to-media.yaml`,
   `-database-to-observability.yaml`, `-spegel-mirror.yaml`, `-misc-to-network.yaml`). The last two
   needed judgment calls beyond a plain source/dest/port copy from the flow table:
   - **spegel**: `hostPort`-based node-to-node image-mirror traffic, not a real namespace
     dependency (per the note above) — modeled as source-scoped-only (`allow-spegel-mirror`,
     `selector: all()` destination) rather than a narrow pair, since the destination is genuinely
     "whichever pod on that node happens to be pulling an image," not one fixed app.
   - **misc → network**: lower confidence than the others — this is really a symptom of a bigger,
     not-yet-designed question ("who's allowed to reach envoy-internal/envoy-external as a
     destination", since `network` is the whole cluster's ingress point) rather than a normal
     app-to-app pair. **Superseded in the round-2 review below** (`allow-misc-to-network` deleted,
     replaced by `allow-cluster-to-network-https`) once `paperless-ngx` and `immich-server` showed
     the same pattern from different namespaces - three source namespaces made narrow pairs the
     wrong shape.
5. ✅ **Allow same-namespace ingress, everywhere** (`components/common/networkpolicy-same-namespace.yaml`)
   — found missing via real `pending_actions` data (see Verification below), not planned
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
   - `allow-trusted-vlans-to-loki` / `-akvorado` / `-fluent-bit` — real observed data-ingestion
     traffic (NAS's Alloy agent to Loki, network gear's NetFlow to Akvorado's inlet, network
     gear's syslog to fluent-bit), each scoped to its specific app + real port. Narrower source
     list than envoy-internal/-external on purpose (confirmed 2026-08-22): only `10.10.0.0/16`
     and `10.20.0.0/16` actually send anything here, not the full trusted-VLAN set - but *not*
     just `10.20.0.0/16` alone either: the primary switch's own management IP is `10.10.0.1`
     (docs/network-observability-plan.md), a different VLAN entirely. akvorado and fluent-bit
     additionally allow `10.2.0.1/32` (OPNsense's own transit address) - OPNsense sends its own
     NetFlow/syslog directly, not just switches, and that address isn't in either VLAN block.
7. ✅ **Default-deny ingress, everywhere** — promoted 2026-08-22/23. Confirmed live (this whole
   plan's central finding, see step 5 and the Verification sections): this was never a separate
   "flip a switch" step - promoting every staged Allow rule from steps 1-6 to real, enforcing
   policy *is* what creates the default-deny effect, because a `selector: all()` policy going
   enforcing ends Calico's permissive per-namespace `kns.<ns>` Profile fallback for literally every
   pod in the cluster simultaneously. That's also why this had to happen as one atomic change
   across all ~16 files (15 `GlobalNetworkPolicy` + the namespaced `allow-same-namespace`
   `NetworkPolicy`) rather than gradually or per-namespace - no partial rollout was possible once
   any one of the wide rules went live. Files renamed to drop the `staged` prefix
   (`stagedglobalnetworkpolicy-*.yaml` → `globalnetworkpolicy-*.yaml`, same pattern for the
   namespaced one) to match what they now actually are.
   >
   > **Correction (2026-08-23): it did NOT land atomically in practice**, despite the design
   > requiring it - see `docs/incidents/2026-08-23-dns-outage.md` for the full RCA. The namespaced
   > half (`allow-same-namespace`, applied by the root `cluster-apps` Kustomization) and the Global
   > half (`allow-dns-ingress` and the rest, applied by the separate `kube-system/calico-policies`
   > Kustomization) were never actually coupled by anything Flux enforces - only by both
   > *usually* reconciling within seconds of each other. `calico-policies` got stuck behind a
   > bogus `rook-ceph-cluster` dependency on its parent `calico` Kustomization (unrelated
   > copy-paste bug, since fixed), the namespaced half landed alone, and the gap between them broke
   > cross-namespace DNS cluster-wide for ~39 minutes. Fixed live via a Flux-bypassing `kubectl
   > apply`; `calico`'s bogus dependency removed so this can't recur *this way*, but the two halves
   > are still not atomic *by construction* - see that doc's "still true" section before doing
   > another large staged-policy promotion or a full cluster rebuild.
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

## Verification round 2 (2026-08-22) - after exercising every app

User manually opened every app (internal routes) and hit external routes from both inside and
outside the network, specifically to generate coverage the earlier passive review couldn't -
confirmed the value of this over just waiting, per the original "test a bunch of apps" plan.
Re-queried Goldmane, filtered strictly to flows recorded after each relevant policy's actual
`creationTimestamp` (not just "recent" - an earlier pass in this round briefly mis-flagged
`PUBLIC NETWORK -> envoy-external` as still broken using data from 10 seconds *before* the fixing
policy existed). After the correct filter, no fresh `PUBLIC NETWORK` flow of any kind exists yet
in Goldmane's retained window - **still unconfirmed either way**, not resolved. Needs a genuine
post-fix external request and a re-check before trusting `allow-opnsense-to-envoy-external`.

Real, consistent findings (not stale-data artifacts):
- **CloudNativePG's operator couldn't reach the instances it manages** - `postgres-operator`
  (`database`) -> 8 different Postgres pods across `authentik`, `home`, `immich`, `misc` on
  `tcp/8000` (the instance manager's own API). Fixed: `allow-postgres-operator-webhook`,
  source-scoped-only like `allow-apiserver-webhooks` (CNPG spans too many namespaces for narrow
  pairs, same reasoning as spegel).
- **changedetection -> llama-cpp** (`home` -> `ai`, `tcp/8080`) - changedetection sends prompts to
  llama-cpp's API as one of its watched targets. Fixed: `allow-changedetection-to-llama-cpp`,
  narrow pair.
- **The misc-to-network pattern turned out to be general, not a one-off** - `paperless-ngx`
  (`home`) and `immich-server` (`immich`) showed the identical shape as forgejo's CronJob
  (calling out through envoy-internal/envoy-external to a hostname that resolves back to the
  Gateway VIP). Three source namespaces made narrow pairs the wrong tool. Fixed: deleted
  `allow-misc-to-network`, replaced with `allow-cluster-to-network-https` - any real Calico
  WorkloadEndpoint (not arbitrary external IPs - `source: {selector: all()}`, never an empty/
  omitted `source`, which would've undone the trusted-VLAN/OPNsense scoping on the sibling rules)
  can reach either gateway's pods on `10443`.

False alarms, resolved without a policy change:
- **`PRIVATE NETWORK -> observability/alertmanager:9093` direct-to-pod** - looked like an
  HTTPRoute bypass at first ("that is weird"). Explained: a `kubectl port-forward -n observability
  svc/kube-prometheus-stack-alertmanager` left running from earlier debugging in this same
  session. `kubectl port-forward` always tunnels through the API server straight to the pod,
  bypassing Gateway API routing entirely by design - not a real access-path problem, no policy
  needed.
- **A batch of same-namespace `download` CronJob flows** (`arr-notifications`, `configarr`,
  `prowlarr-bootstrap`, `qui-bootstrap`, each -> their target `*arr`/`qui` app) showed one-off
  `EndOfTier: Deny` despite `allow-same-namespace` existing. Confirmed transient: re-checking the
  *same* recurring conversation (e.g. `configarr -> radarr:7878`) across multiple runs showed
  correct `Allow` every time except the one sample that happened to land right as that run's
  brand-new Job pod was created - a Felix/Goldmane endpoint-cache-sync timing artifact on freshly
  spawned pods, self-corrects on the next aggregation window, not a policy gap.

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
- **Grafana visibility: implemented 2026-08-22** (`calico-deny-log-shipper`,
  `kubernetes/apps/observability/calico-deny-log-shipper/`). Went with the poller option, not the
  `Log`-then-`Deny` iptables approach - no live logging cost per enforced deny, and reuses the
  exact `whisker-backend` HTTP+JSON API already proven working all through this plan's
  verification passes, rather than Goldmane's raw gRPC stream (which is what the one piece of
  prior art found online - a homelab OTLP/HTTP exporter - has to speak instead). A 1-minute
  CronJob polls a deliberately-overlapping 3-minute window, filters to `action: Deny`, and ships
  each hit to Loki as a structured JSON log line (`job="calico-deny-log"`) using the flow's own
  `end_time` as the log timestamp - so re-fetching the same flow across overlapping runs lands as
  an exact (timestamp, line) duplicate, which Loki accepts as a no-op instead of double-counting.
  Dashboard: `kubernetes/apps/observability/grafana/app/calico-deny-dashboard.yaml` ("Network"
  folder) - total-in-range stat, deny-rate-over-time, and the table this was actually built for:
  unique source→destination deny hits with counts, sorted descending, for the selected time
  range. Needed a second Calico policy rule (`observability` added to
  `allow-whisker-envoy-ingress` in `kube-system/calico/route/networkpolicy.yaml`) since the
  shipper reaches `whisker-backend` directly in-cluster rather than through the SSO-wrapped
  HTTPRoute - a CronJob can't do an interactive OIDC login.
  - **Not done, and deliberately not implemented alongside this**: proactive Slack/Alertmanager
    alerting on deny rate. The dashboard covers "look and see"; "notify me automatically" is a
    separate decision (threshold tuning, alert fatigue risk) - revisit once the dashboard has
    run for a while and shows what a normal baseline deny rate even looks like.

## Open questions

- Does every app in a fan-out namespace (`media`, `download`, etc.) actually need ingress from
  *all* of `network`'s traffic, or would scoping to specific ports per app (rather than a blanket
  namespace-level allow) be worth the extra policy surface? Leaning toward namespace-level for
  the baseline, app-level as a later tightening pass if it turns out to matter.
- ~~Whether `kube-system → *` (spegel) should be a real per-namespace allow or whether it's
  cleaner to just exempt `kube-system` as a source everywhere, given its cluster-wide-by-design
  nature.~~ Resolved in step 4: modeled as source-scoped-only (`allow-spegel-mirror`, destination
  `selector: all()`), not a full source exemption — still requires port 5000 specifically.
- ~~**New from step 4**: who should be allowed to reach `network` namespace pods (envoy-internal/
  envoy-external) as a *destination*?~~ Answered by step 6 + the round-2 review: trusted-VLAN
  devices and OPNsense (external clients) via the step-6 rules, plus any cluster pod on https via
  `allow-cluster-to-network-https`. kube-vip's DNAT does put traffic through the normal pod-ingress
  policy path - confirmed live via Goldmane flow data (`PRIVATE NETWORK`/`PUBLIC NETWORK` sources
  show up and get evaluated normally), so the concern about it landing somewhere policy can't see
  didn't pan out.
