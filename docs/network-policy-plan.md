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

1. **Cluster-wide allow: DNS.** One `GlobalNetworkPolicy` (or a `StagedGlobalNetworkPolicy`
   first) permitting egress to `kube-system`/coredns on `udp/53` from every pod, unconditionally.
2. **Cluster-wide allow: ingress from `network`.** A policy (or per-namespace policies sharing
   this one rule) allowing ingress from pods in the `network` namespace
   (`namespaceSelector: matchLabels: {kubernetes.io/metadata.name: network}` — the
   auto-populated namespace-name label, no custom namespace labeling needed) to whatever port(s)
   each app's Service actually exposes.
3. **Cluster-wide allow: ingress from `observability`.** Same shape, sourced from
   `observability`, covering each app's metrics/health port(s).
4. **The narrow pairs above**, each as its own small, explicit rule scoped to just that
   source/dest/port.
5. **Default-deny ingress**, per namespace, once 1-4 are confirmed correct via staged mode —
   this is the step that actually turns "nothing enforced" into "namespace isolation by
   default," and it only goes in after watching real traffic against the staged version of
   everything above and confirming nothing legitimate gets flagged as would-be-denied.
6. **Egress**, as a deliberate separate decision per namespace (not bundled into this ingress
   baseline) — `download`'s internet-bound traffic is the obvious first case to think through.

## Open questions

- Does every app in a fan-out namespace (`media`, `download`, etc.) actually need ingress from
  *all* of `network`'s traffic, or would scoping to specific ports per app (rather than a blanket
  namespace-level allow) be worth the extra policy surface? Leaning toward namespace-level for
  the baseline, app-level as a later tightening pass if it turns out to matter.
- `download`'s egress (392 observed flows, by far the largest single traffic pattern in this
  data) isn't addressed by this ingress-focused plan at all yet — worth a explicit decision
  once the ingress baseline is live and stable.
- Whether `kube-system → *` (spegel) should be a real per-namespace allow or whether it's
  cleaner to just exempt `kube-system` as a source everywhere, given its cluster-wide-by-design
  nature.
