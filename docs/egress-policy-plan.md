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
| `download → PUBLIC NETWORK`, mostly high-port UDP | The actual point of `download` existing - indexer HTTPS calls (`tcp/443`) plus qBittorrent's DHT/peer traffic (hundreds of distinct ephemeral UDP ports in one 15-second sample, one per swarm peer). Staged below as a deliberately broad `0.0.0.0/0` allow (matches the ingress plan's own reasoning for `allow-opnsense-to-envoy-external`: this namespace's whole job is public internet exposure/access, so a source-IP-style narrow allowlist doesn't fit the actual need - the port-list would be unbounded and pointless to enumerate). |
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

## What's deliberately NOT staged yet

- `home`'s LAN-device egress (ESPHome/frigate/SSDP) - needs VLAN confirmation first.
- The small/unconfirmed `PUBLIC NETWORK tcp/443` calls from `authentik`/`misc`/`media`/`immich`.
- Any narrowing of the two broad `network`/`observability` cluster-wide egress allows down to specific ports per destination - same "open question" the ingress plan left for its own `network`/`observability` ingress rules; revisit together once there's real usage data either way.
- The actual default-deny-egress effect itself - **not a separate policy to write**. Exactly like ingress step 7: once every `selector: all()` Egress-type policy above is promoted from staged to enforcing, the permissive per-namespace `kns.<ns>` Profile fallback ends for egress on every pod simultaneously, and that *is* default-deny. No explicit "deny all" object needed or wanted. When that promotion happens, it must land as one atomic change for the same reason ingress step 7 had to - see `docs/incidents/2026-08-23-dns-outage.md` before attempting it, and re-read network-policy-plan.md's step 7 correction about the two Kustomizations not being atomic *by construction*.

## Next steps

1. Land the 8 staged files above, let `calico-policies` reconcile.
2. Watch `whisker.internal.oreillys.io` / the `calico-deny-log-shipper` → Grafana "Network" dashboard's pending-diff table for a representative window (the ingress plan used about 2-3 days of real usage, including deliberately exercising apps, before promoting).
3. Review real `pending_actions` data the same way the ingress plan's Verification sections did - confirm the broad `network`/`observability` allows aren't hiding a real gap, and look for anything unexpected trying to reach the internet that isn't in the flow-data review above.
4. Resolve the deferred items (`home` VLAN scope, the small PUBLIC:443 calls) with the same rigor the ingress plan used - real data, not guesses.
5. Only then: promote everything to enforcing in one atomic change, learning from the ingress rollout's one real incident.
