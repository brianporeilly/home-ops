# Ceph CephX Key Type Migration Plan (aes → aes256k)

Status: **Phase 1 (daemon rotation) done and verified live.** PR #634 (+ a follow-up fixing
`keyGeneration: 1` being a silent no-op — must be strictly greater than the live baseline, not
just non-zero) rotated mon/osd/mgr/mds/rgw/admin/crash/ceph-exporter to `aes256k` — confirmed via
`ceph health detail` dropping from `HEALTH_ERR` (14 insecure daemon-side entities) to `HEALTH_WARN`
(0). `daemon.keyType` was then removed once rotation was confirmed complete, clearing
`AUTH_EMERGENCY_CIPHERS_SET` (Rook sets `--mon-auth-emergency-allowed-ciphers` on every mon for as
long as that field is non-empty, regardless of rotation state). `keyGeneration`/`keyRotationPolicy`
stay set — the CRD forbids removing `keyGeneration` once introduced, and leaving
`keyRotationPolicy: KeyGeneration` means a future rotation is just a `keyGeneration` bump +
re-adding `keyType`, not restoring the whole block. **Phase 2 (`rbdMirrorPeer`) up as a PR** —
unused entity (no RBD mirroring configured in this cluster), zero risk. Phases 3-4 (CSI,
`allowedCiphers` lockdown) are still separate, later work — CSI stays blocked on node kernel 7.0+.
Written 2026-08-21, same investigation that found and fixed
the [grimmory MariaDB backup break](../kubernetes/apps/media/grimmory/app/backup.yaml) — both
trace back to the same event: the unpinned `rook-ceph-cluster` chart bump (`v1.20.3→v1.20.5`,
PRs #579/#580, merged 2026-08-20) silently carried the cluster's Ceph image from `v20.2.2` to
`v20.2.4`.

## Why this exists: CVE-2025-30156

The `aes`→`aes256k` key type isn't a routine hardening pass — it's Ceph and Rook's coordinated
fix for a formally disclosed CVE ([Ceph CVE-2025-30156](https://ceph.io/en/news/blog/2026/v20-2-4-v19-2-6-combo-released/),
[Rook's advisory](https://medium.com/@b.blaine.gardner/rook-advisory-for-ceph-cve-2025-30156-cc1f8dee6da3)).
Ceph 20.2.4 shipped a new, secure cephx key type (`aes256k` — AES-256 with HMAC-SHA256 signing,
replacing the old plain `aes`/AES-128 cephx keys) alongside the SigV4 hardening that broke the
MariaDB backup. Every key in this cluster was minted under the only type that existed before
20.2.4, so `ceph health detail` now flags all of them:

```
[WRN] AUTH_INSECURE_CLIENT_KEY_TYPE: 9 auth client entities with insecure key types
    client.admin, client.ceph-exporter, client.crash, client.csi-cephfs-node.1,
    client.csi-cephfs-provisioner.1, client.csi-rbd-node.1, client.csi-rbd-provisioner.1,
    client.rbd-mirror-peer, client.rgw.ceph.objectstore.a
[WRN] AUTH_INSECURE_KEYS_ALLOWED: Monitors are configured to allow auth using insecure key types
[WRN] AUTH_INSECURE_KEYS_CREATABLE: Monitors are configured to allow creation of insecure key types
[ERR] AUTH_INSECURE_SERVICE_KEY_TYPE: 10 auth service entities with insecure key types
    mds.ceph-filesystem-a, mds.ceph-filesystem-b, osd.0-5 (×6), mgr.a, mgr.b
[WRN] PG_NOT_DEEP_SCRUBBED: 1 pgs not deep-scrubbed in time   (unrelated, expected to self-heal)
```

19 entities total. Nothing is currently broken by this — `AUTH_INSECURE_KEYS_ALLOWED` means the
mons still accept the old key type, so the cluster keeps working exactly as before. This is a
"close the door before someone uses it" fix, not an active outage.

## The good news: Rook already automates this

Initially assumed this would need hand-rolled `ceph auth rotate` / `get-or-create-pending` /
`commit-pending` calls per entity (Ceph 20.2.4 does expose those primitives directly — see
`AuthMonitor.cc`'s pending-key mechanism, which keeps the **old key valid until the new one is
successfully used**, so it's a safe rollover even by hand). But Rook **v1.20.5+ has native,
declarative support for exactly this**, added specifically for this CVE
([rook/rook#18189](https://github.com/rook/rook/pull/18189),
[Rook's CephX key rotation docs](https://rook.io/docs/rook/latest-release/Storage-Configuration/Advanced/cephx-key-rotation/)).
We're already on **Rook v1.20.6** (confirmed live) — no Rook upgrade needed to start.

Confirmed live against this cluster's installed `CephCluster` CRD schema
(`cephclusters.ceph.rook.io`) — the fields below are real, not doc-summarized:

```yaml
# kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml, under spec.values.cephClusterSpec
security:
  cephx:
    daemon:
      keyRotationPolicy: KeyGeneration
      keyGeneration: 1          # bump to rotate; must only ever increase
      keyType: aes256k
    csi:
      keyRotationPolicy: KeyGeneration
      keyGeneration: 1
      keyType: aes256k
      keepPriorKeyCountMax: 1    # keep old key valid so in-flight mounts don't break
    rbdMirrorPeer:
      keyRotationPolicy: KeyGeneration
      keyGeneration: 1
      keyType: aes256k
    allowedCiphers: [aes, aes256k]   # final lockdown step: narrow to [aes256k] only, last
```

- `daemon` covers everything **not** CSI or rbd-mirror-peer: `client.admin`, `client.crash`,
  `client.ceph-exporter`, `client.rgw.ceph.objectstore.a`, `mds.*`, `osd.*`, `mgr.*` (confirmed —
  that's 14 entities, exactly matching `9 + 10 - 4 csi - 1 rbd-mirror-peer` from the health
  detail above). Rook's docs state daemon rotation **does not affect client connections** —
  keys rotate via the same old-key-stays-valid-until-used mechanism Ceph exposes natively.
- `csi` covers the 4 `client.csi-*` entities used by Ceph-CSI for PVC provisioning/mounting.
  Explicitly flagged as higher-risk by Rook's own schema: *"CSI key rotation can affect existing
  PV connections, so take care."* `keepPriorKeyCountMax: 1` mitigates that — old + new key both
  valid until pods remount.
- `rbdMirrorPeer` covers `client.rbd-mirror-peer`. **Checked: RBD mirroring is not configured in
  this cluster** (no `CephRBDMirror` resource, both blockpools have `mirroring.enabled` unset) —
  Rook creates this identity by default regardless. Zero operational risk either way; lowest
  priority.
- `allowedCiphers` is the mon-level door that's currently propping `AUTH_INSECURE_KEYS_ALLOWED`/
  `_CREATABLE` open. Rook's own CRD doc string calls this out explicitly: *"can disrupt cluster
  availability! Review Rook documentation carefully before setting this in a production
  cluster!"* Must be the **last** step, only after every entity is confirmed on `aes256k` —
  narrowing this while anything still authenticates with `aes` would lock that entity out.

## The one real blocker: CSI needs kernel 7.0+

Rook's docs are explicit: Ceph-CSI kernel mounts (RBD/CephFS via the in-kernel client, not
userspace) need **Linux kernel 7.0+** for `aes256k` support (7.2+ for FIPS). Every node in this
cluster is currently `6.12.102-flatcar` (confirmed via `kubectl get nodes` — all 8 nodes,
identical). **Setting CSI `keyType: aes256k` today would break PVC mounts on every node.**

This means the plan has a **hard split**:
- **Daemon + rbd-mirror-peer rotation can happen now** — no kernel dependency, userspace
  processes, Rook-confirmed non-disruptive.
- **CSI rotation is blocked** until node kernels reach 7.0+. That's a separate, larger fleet-wide
  OS/kernel upgrade project (Flatcar version bump across all 8 nodes), not something to fold into
  this plan. Track it as its own follow-up; re-check Flatcar's shipped kernel version
  periodically rather than guessing at a timeline here.

## Proposed order

1. ✅ **Pilot: `daemon` rotation** (PR #634). Add the `security.cephx.daemon` block above
   (`keyRotationPolicy: KeyGeneration`, `keyGeneration: 1`, `keyType: aes256k`) to
   `cluster/helmrelease.yaml`, PR it, merge, let Flux reconcile. Watch `status.cephx` on the
   `CephCluster` resource per-entity as it rolls out, and confirm `ceph health detail` drops the
   14 daemon-side entities from `AUTH_INSECURE_SERVICE_KEY_TYPE`/`AUTH_INSECURE_CLIENT_KEY_TYPE`.
   Rollback is one line: set `keyType: aes` and bump `keyGeneration` again — Rook rotates back.
2. ✅ **`rbdMirrorPeer` rotation.** Same shape, unused entity, effectively zero risk.
3. **(Blocked) CSI rotation.** Revisit once node kernels are 7.0+. When ready: set
   `csi.keyType: aes256k`, `keyRotationPolicy: KeyGeneration`, bump `keyGeneration`,
   `keepPriorKeyCountMax: 1` first — verify existing PVC mounts survive — then drop to `0` once
   confirmed, per Rook's documented CSI migration steps (drain/uncordon each node so pods
   remount with the new key).
4. **Final lockdown: `allowedCiphers: [aes256k]`.** Only after (1)–(3) are all done and
   `ceph health detail` shows zero `AUTH_INSECURE_*` warnings. This is what actually closes
   `AUTH_INSECURE_KEYS_ALLOWED`/`_CREATABLE` and is explicitly the riskiest single change per
   Rook's own docs — do it deliberately, not bundled with anything else, and confirm cluster
   health immediately after.

## Verification

- `ceph health detail` — the four `AUTH_INSECURE_*` checks should clear entity-by-entity as each
  phase lands, and disappear entirely after step 4.
- `kubectl get cephcluster -n rook-ceph -o yaml` → `status.cephx` — per-component
  `keyGeneration`/`keyType` actuals, confirms Rook finished rotating vs. still in progress.
- `ceph auth ls` / `ceph auth get <entity>` — spot-check a rotated entity's `type_str` directly
  against the mon if `status.cephx` is ambiguous.

## Open questions (not blocking, but unresolved)

- No firm timeline for Flatcar shipping a 7.0+ kernel — re-check when revisiting phase 3, don't
  assume a date.
- Whether to mute `AUTH_INSECURE_*` in Alertmanager/Gatus between phase 1 and phase 4 (the alert
  stays partially active for weeks/months while phase 3 is blocked on kernel upgrades) — worth a
  explicit decision once phase 1 lands, so the alert isn't just permanently noisy in the
  interim.
