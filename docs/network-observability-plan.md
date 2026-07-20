# Network Device Observability Plan

Goal: get metrics, logs, and (where meaningful) flow data from OPNsense and the
MikroTik CRS305 switches into the existing Prometheus / Loki / Grafana stack.

Devices:
- OPNsense router — `10.2.0.1`
- MikroTik CRS305 switches ×N — **running RouterOS** (confirmed, not SwOS).
  Primary switch `10.10.0.1` is provisioned; a second (`10.10.0.2`) is not
  online yet and isn't covered by anything below.

---

## Status as of 2026-07-19 — start here for a fresh session

The three pillars below (SNMP, syslog, goflow2 NetFlow) are **all done and
merged**. A fourth pillar not in the original plan — **Akvorado**, a
purpose-built NetFlow analyzer — was added afterward and is also done and
merged, running alongside goflow2.

### Done
- **SNMP** (Pillar 1): metrics flowing for OPNsense + primary MikroTik switch,
  including advanced host/board health modules (CPU/mem/disk for OPNsense,
  temperature/optical/firmware for the switch). Grafana dashboard (community
  `SNMP Stats`, id 11169) and 8 alert rules shipped.
- **Syslog** (Pillar 2): both devices confirmed sending. MikroTik gotcha worth
  remembering — a single logging rule with multiple topics
  (`topics=info,warning,error,critical`) silently required **all** of them to
  match before sending; fixed by splitting into one rule per topic. Loki
  content alerts added (`SyslogDeviceSilent` per device, `SyslogErrorRateHigh`
  keyword-based).
- **NetFlow via goflow2** (Pillar 3): collector-health dashboard + a per-host
  traffic dashboard (top talkers, by-protocol, by-port — built on a
  `job=netflow` Loki stream fed by a dedicated fluent-bit pipeline, JSON body
  only, deliberately no high-cardinality Loki labels). Alerts shipped.
- **Reliability hardening** (opportunistic, not in original plan): fluent-bit
  switched to disk-backed chunk buffering (was memory-only, caused dropped
  logs on a Loki restart), Prometheus bumped to 2 replicas, Loki
  `max_query_series` raised (500 → 5000, was blocking per-host queries).
- **Akvorado** (new 4th pillar): full NetFlow analyzer with GeoIP/ASN/SNMP
  enrichment and its own UI, run **alongside** goflow2 (not replacing it —
  intent is to retire goflow2 once Akvorado is proven out, deliberately not
  done yet). New infra this required:
  - `kubernetes/apps/data/` (new top-level category) — Redpanda Operator +
    single-broker `Redpanda` CR, positioned as a **shared/reusable**
    Kafka-compatible bus, not Akvorado-exclusive. TLS disabled (internal-only
    traffic, no cert-manager Issuer set up for it — see "decided against"
    below). Internal Kafka listener is port **9093**, not the standard 9092.
  - `kubernetes/apps/database/clickhouse/` — Altinity ClickHouse Operator,
    same "operator lives here, per-app instances live with their app"
    convention as CloudNativePG/MariaDB. **Must explicitly set**
    `configs.files."config.yaml".watch.namespaces.include: [".*"]` in the
    operator's HelmRelease values — its chart default only watches its own
    namespace unless running in `kube-system`, which silently means it never
    sees CRs created in other namespaces.
  - `kubernetes/apps/observability/akvorado/` — the app itself, 4 controllers
    (orchestrator/inlet/outlet/console). Akvorado 2.x moved SNMP/GeoIP
    enrichment from inlet to **outlet** (inlet is now just a raw UDP→Kafka
    relay) — matters if referencing older docs/blog posts.

### Hard-won debugging notes (read before touching Akvorado again)
A long live-debugging session turned up a chain of unrelated bugs, roughly in
the order hit — useful if something regresses or this gets redeployed fresh:
1. Redpanda's internal Kafka port defaults to **9093**, not 9092.
2. Redpanda's chart defaults `tls.enabled: true`, needing cert-manager
   Issuers never set up — disabled TLS entirely instead.
3. ClickHouse operator's namespace-watch scoping (see above).
4. `ClickHouseInstallation` pod template needs an explicit container `image:`
   — the operator does not default it; omitting it fails StatefulSet creation
   with a confusing "should recreate" retry loop that masks the real
   `containers[0].image: Required value` error underneath.
5. Altinity operator does **not** auto-refresh a ClickHouse user's password
   when the referenced Secret's value changes after creation — bump
   `spec.taskID` on the `ClickHouseInstallation` to force a resync.
6. Akvorado's ClickHouse hostname: the operator's real generated Service name
   is `clickhouse-<chi-name>`, not `<chi-name>` itself.
7. **The actual root cause of a persistent "WRONG_PASSWORD" error**: Akvorado's
   env-var override convention requires the process name in the prefix
   (`AKVORADO_CFG_ORCHESTRATOR_CLICKHOUSEDB_PASSWORD`), not just
   `AKVORADO_CFG_CLICKHOUSEDB_PASSWORD` — orchestrator was silently
   connecting with an empty password the whole time. ClickHouse's
   `plaintext_password` auth type ruled out any hash-negotiation theory before
   this was found; direct `clickhouse-client` testing confirmed the real
   password worked fine, isolating the bug to Akvorado's own config binding.
8. `console.yaml` (one of Akvorado's 4 per-process config files, mounted
   alongside `akvorado.yaml`) must have **real content**, not just `{}` — an
   empty document meant orchestrator never registered an HTTP route to serve
   it, causing a 404 that console's client misreported as "not YAML".
9. MaxMind's GeoIP daily download quota got exhausted by the repeated
   crash-loop restarts during all of the above (each restart = a fresh
   `geoipupdate` sidecar attempt). The `geoipupdate` sidecars on
   orchestrator/outlet were **temporarily removed** (commit in PR #186) since
   the non-zero exit on a 429 was blocking pod readiness even after every
   other bug was fixed. `geoip.optional: true` means Akvorado runs fine
   without them. **Re-add once the quota resets** (roughly 24h from
   2026-07-19 ~22:00 UTC) — restore the `geoipupdate` container blocks and
   their `persistence.geoip-*.advancedMounts.*.geoipupdate` entries that were
   removed from `helmrelease.yaml`.

### Not yet done — pick up here
- **Device-side: add Akvorado as a second NetFlow export target.** OPNsense
  and the MikroTik switch are still only exporting to goflow2
  (`10.20.250.5:2055`). Need to add Akvorado's inlet
  (`10.20.250.6:2055`) as an additional target on both, per the device
  commands already in Pillar 3 above (swap the IP).
- Re-add `geoipupdate` sidecars once MaxMind's quota resets (see above).
- Haven't yet browsed `akvorado.internal.oreillys.io` to confirm the console
  UI itself works end-to-end and is showing real flow data — cluster-side
  health is confirmed (`HelmRelease Ready`, all 4 pods `1/1 Running`), but
  the actual UI/data-in-ClickHouse hasn't been eyeballed.
- Second MikroTik switch (`10.10.0.2`) still not provisioned — nothing
  (SNMP/syslog/netflow) covers it yet.
- MikroTik RouterBOARD firmware is behind (`mtxrFirmwareVersion` 7.18.2 vs
  `mtxrFirmwareUpgradeVersion` 7.23.2 available) — unrelated to observability,
  noticed via SNMP data, needs a manual `/system routerboard upgrade` + reboot
  whenever convenient.

### Decided against (don't re-litigate without a new reason)
- **Redpanda TLS via cert-manager** — cert-manager's already running in this
  cluster and it'd be easy to wire up, but the ongoing cost (every future
  Kafka consumer needs matching client TLS config + a trusted CA bundle) isn't
  worth it for traffic that never leaves cluster-internal pod-to-pod
  communication.
- **Grafana HA / Postgres-backed Grafana** — `persistence.enabled: false`
  already, so Grafana is already fully ephemeral/config-driven; 2 replicas
  wouldn't lose anything not already lost on every restart. The one real gap
  (session cookies not shared across replicas) is a session-affinity fix, not
  a reason to add a database. Not done because HA wasn't actually needed, not
  because of a blocker.
- **Loki HA** — would need a migration off local-filesystem storage to an
  S3-compatible backend (self-hosted MinIO or Ceph RGW) plus switching
  `deploymentMode` away from `SingleBinary`. Real project, deliberately not
  bundled into this work.
- **DIY hostname/GeoIP enrichment on goflow2's own dashboards** — this is what
  prompted evaluating Akvorado in the first place; superseded by just running
  a purpose-built tool instead of hand-building the enrichment.

---

## Current state (found while scoping this)

`kubernetes/apps/observability/snmp-exporter/` already exists on this branch but
is incomplete and has two copy/paste bugs from `smartctl-exporter`:

- `app/secret.yaml` contains the **grafana-admin-secret** (wrong secret, unrelated to SNMP)
- `app/prometheusrule.yaml` contains **smartctl alert rules**, not SNMP ones
- The app's `ks.yaml` is **not referenced** in `kubernetes/apps/observability/kustomization.yaml`, so Flux isn't reconciling it at all yet
- `helmrelease.yaml` has one target wired up (`opnsense` / `10.2.0.1` / module `if_mib` / auth `public_v2`) — auth `public_v2` means SNMPv2c with community string `public`, the well-known default. Should be changed before exposing this to real devices.

These need to be cleaned up as step zero regardless of the rest of this plan.

---

## Pillar 1 — SNMP metrics (snmp_exporter → Prometheus → Grafana)

**Chart:** `prometheus-community/prometheus-snmp-exporter` (already added, OCI pinned `9.6.2`)

### Device-side setup

**OPNsense:**
- Services → SNMP: enable, set a non-default community string (or configure SNMPv3), bind to the interface reachable from the cluster
- Optionally enable extra bsnmpd modules (`hostres` for CPU/mem, `pf` for firewall state table) for richer data beyond interface counters

**MikroTik CRS305 (RouterOS):**
- IP → SNMP: enable, set community (or SNMPv3 user with authPriv), restrict access via the SNMP community's allowed-address if desired
- RouterOS exposes the standard `IF-MIB` plus MikroTik's private `MTXR-MIB` (health: temperature/voltage, and PoE where hardware supports it)

**Security note:** SNMPv2c sends the community string in plaintext. Recommend SNMPv3 (authPriv) for anything beyond a quick first pass — snmp_exporter supports v3 auths natively. If staying on v2c for simplicity, at minimum stop using the literal string `public`.

### Kubernetes-side work

1. Fix `secret.yaml` and `prometheusrule.yaml` (see bugs above) — the secret should hold the real SNMP v2c community / v3 credentials (sops-encrypted like the rest of the repo), the PrometheusRule should have SNMP-relevant alerts (`snmp_up == 0`, interface down/flapping, high error/discard rate)
2. Add `./snmp-exporter/ks.yaml` to `kubernetes/apps/observability/kustomization.yaml`
3. Check what modules the chart's bundled `snmp.yml` actually ships (`if_mib` is generic and safe for both devices' interface counters). For MikroTik health OIDs, may need a custom generator config using MTXR-MIB — worth checking after `if_mib` is working end-to-end, not before
4. Add one `params` entry per CRS305 switch in the HelmRelease (same shape as the existing OPNsense entry)
5. `serviceMonitor` is already enabled in the HelmRelease — once the above is fixed, Prometheus should start scraping automatically

### Grafana

Import a community SNMP interface dashboard as a starting point (e.g. the standard "SNMP Interface" style dashboards built around `ifHCInOctets`/`ifHCOutOctets`), then tune per-device.

---

## Pillar 2 — Syslog (OPNsense + MikroTik → Loki)

Decision: extend the existing `fluent-bit` DaemonSet rather than stand up a separate receiver.

Today `fluent-bit` only has a `tail` input for container logs → Loki. Plan:

1. Add a `[INPUT] syslog` block (`mode udp`, `listen 0.0.0.0`, a non-privileged port like `5514` since the DaemonSet doesn't run privileged/hostNetwork today)
2. Add a `rewrite_tag` (or similar) filter so OPNsense and MikroTik logs land under distinct tags — lets Loki labels distinguish `job=syslog-opnsense` vs `job=syslog-mikrotik` instead of one blended stream
3. Extend (or add) an `[OUTPUT] loki` block matching the new syslog tag(s), same target (`loki-headless.observability.svc.cluster.local:3100`) as today
4. Expose a new **Service** (`type: LoadBalancer`, `kubevip.io/loadbalancerIPs: "<ip>"`, same pattern as `omada-controller`) with a UDP port for syslog — since this is a DaemonSet behind a normal LB Service, kube-proxy will land traffic on some pod regardless of node; that's fine for syslog

**Parser note:** RouterOS's syslog output isn't strictly RFC3164/5424-compliant in all cases — plan to use fluent-bit's built-in `syslog-rfc3164` parser first, but expect to need a custom regex parser once real MikroTik log lines are seen. Budget time for this rather than assuming it works first try.

### Device-side setup

**OPNsense:** System → Settings → Logging/Targets → add a remote target: transport UDP, destination = the new LB IP, port `5514`, pick facilities (system, firewall at minimum)

**MikroTik (RouterOS):**
```
/system logging action add name=remote target=remote remote=<LB-IP> remote-port=5514
/system logging add topics=info,warning,error,critical action=remote
```
Add more topics (e.g. `firewall`, `interface`) as desired once the basic pipe is confirmed working.

---

## Pillar 3 — NetFlow

Since both CRS305 switches are confirmed on **RouterOS**, NetFlow export is possible on both. However:

**Important caveat on the switches:** the CRS305 hardware-switches most VLAN/L2 traffic in the ASIC fast path. RouterOS's `/ip traffic-flow` only sees packets that pass through the CPU (routed/bridged-with-CPU-involvement traffic) — it does **not** see ASIC-switched frames. In practice this means NetFlow from the switches will likely show little to nothing for normal switched traffic, and is mostly useful only if the switch is doing L3 routing itself. **OPNsense is the netflow source that actually matters** — as a router, it sees and can account for all routed traffic. Recommend treating switch-side netflow as a low-priority/optional add rather than a primary goal, so there's no surprise when the switch dashboards look empty.

### Collector choice: goflow2

`netsampler/goflow2` — single lightweight container, supports NetFlow v5/v9 and IPFIX, exposes a native Prometheus metrics endpoint (flow/byte counters by exporter), and can optionally emit JSON per-flow records to stdout for tailing into Loki later if flow-level search is wanted. No official Helm chart, so this would be wrapped with the `bjw-s` app-template (same pattern already used for `omada-controller`) rather than an upstream chart.

### Kubernetes-side work

New app `kubernetes/apps/observability/goflow2/`:
1. `HelmRelease` using `app-template`, container image `netsampler/goflow2`, listening on UDP `2055` (netflow) inside the pod
2. `Service` type `LoadBalancer` with a `kubevip.io/loadbalancerIPs` annotation for UDP `2055`
3. `ServiceMonitor` for goflow2's Prometheus metrics port
4. Optional `PrometheusRule` (e.g. `NetflowCollectorDown` if the metrics endpoint stops reporting)

### Device-side setup

**OPNsense:** Reporting → Netflow → enable, capture interfaces = WAN + LAN (whichever routed interfaces matter), export version = v9 (or IPFIX), target = goflow2 LB IP : `2055`

**MikroTik (RouterOS), optional/low-value per caveat above:**
```
/ip traffic-flow set enabled=yes interfaces=all
/ip traffic-flow target add address=<goflow2-LB-IP> port=2055 version=9
```

### Grafana

Community goflow2 dashboards exist as a starting point; otherwise build simple panels on top of the Prometheus metrics (bytes/flows by exporter) — full "top talkers" style analysis would need the JSON-to-Loki path, which is a reasonable phase-2 addition rather than day-one scope.

---

## Suggested sequencing

1. **Fix the existing snmp-exporter WIP bugs** and wire it into the observability kustomization — quick win, unblocks OPNsense metrics immediately since the target is already configured
2. **SNMP for the CRS305 switches** — add their `params` entries once OPNsense is confirmed working
3. **Syslog via fluent-bit extension** — OPNsense first (RFC-compliant, low risk), then MikroTik (expect to iterate on the parser)
4. **NetFlow via goflow2** — OPNsense only initially; revisit switch-side netflow only if there's a concrete need for it, given the ASIC fast-path caveat

## Open items to confirm before implementing

- SNMPv2c community string vs SNMPv3 — pick one before deploying real credentials
- Exact LoadBalancer IPs to reserve for the syslog port and the goflow2 port (check the kube-vip-cloud-provider CIDR pool for free addresses)
- Whether flow-level (per-conversation) search via Loki is wanted now or is a later nice-to-have
