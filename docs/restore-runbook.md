# Restore Runbook

Status: drafted 2026-08-15, companion to `backup-dr-plan.md` (design/status) and
`migration-inventory.md`. This is the **procedure** doc that plan promised — "what do I actually
type" for each failure scenario, not the design rationale.

**Read this key before trusting anything below:** each section is marked
✅ **proven** (live-tested against a real app/PVC/failure this session, with real data verified
after — not just "pod came back Running") or 🟡 **documented, not tested** (the standard
procedure per the operator's own docs, never actually rehearsed against this cluster). Treat 🟡
sections as a starting point for a real drill, not a guarantee they work as written.

---

## 1. Single app's PVC is gone or corrupted (✅ proven — kopiur `Restore` populator)

Covers: a PVC got deleted by mistake, an app needs to move nodes/storage-class and you want it
re-seeded from backup, or you're validating the restore path works before you need it for real.

Applies to any of the 22 apps with `persistence.<name>.dataSourceRef` wired in their
`app/helmrelease.yaml` (see `migration-inventory.md` for the list). Not DB PVCs — those are CNPG/
MariaDB, see §3.

```
# 1. Suspend BEFORE scaling down - a live Flux/Helm reconcile can race a
#    `scale --replicas=0` and silently scale it back to 1.
flux suspend hr <app> -n <namespace>

# 2. Scale down and confirm it actually stuck (re-check after a few seconds).
kubectl scale deploy/<app> --replicas=0 -n <namespace>
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>

# 3. Delete the PVC. If it hangs in Terminating, something still references
#    it - almost always a leftover completed pod (a finished Job run counts).
#    Find and delete that pod first, then retry the PVC delete.
kubectl delete pvc <pvc-name> -n <namespace>
kubectl get pods -n <namespace> -o wide   # look for anything still mounting it

# 4. Resume - Flux recreates the HelmRelease's full desired state, including
#    the PVC with dataSourceRef set. The CSI populator claims it via the
#    matching Restore CR (kopiur.home-operations.com/v1alpha1, name == app
#    name, from components/kopiur/backup) and runs a mover Job that
#    restores the latest snapshot BEFORE the app's own pod starts.
flux resume hr <app> -n <namespace>

# 5. Watch the PVC bind, then the pod come up.
kubectl get pvc <pvc-name> -n <namespace> -w
kubectl get pods -n <namespace> -w
```

**Verify — don't stop at "pod is Running".** Exec in and check the actual expected files/content
exist with the right ownership, or cross-reference against a separate data store if the PVC's
content is legitimately allowed to be sparse (e.g. an app whose real state lives in Postgres, not
the PVC). "Pod Running" only proves the container started, not that the data is real.

### If the Restore CR fails
Kopia's own notification-listing path triggers an incidental manifest-compaction write attempt,
which fails against the Restore's intentionally-read-only repository connection
(`mkdir /repo/...: read-only file system`). **A failed `Restore` is terminal — kopiur never
retries it automatically.** Fix:

```
kubectl delete restore <app> -n <namespace>
flux reconcile ks <app> -n <namespace>   # recreates the Restore CR from the Kustomization
```

Hit this on both `thelounge` and `immich` during the original rollout; succeeded on retry both
times.

### If the app runs as a non-default UID and the restore is denied CAP_CHOWN
Apps whose `SnapshotPolicy` needed `mover.securityContext: {runAsUser: 0, ..., capabilities:
{add: [DAC_OVERRIDE]}}` to back up in the first place (non-UID-1000 apps — see
`backup-dr-plan.md` §2 L2 gotchas) need the matching restore-side override too:

```yaml
# app's ks.yaml
patches:
  - target:
      kind: Restore
    patch: |
      apiVersion: kopiur.home-operations.com/v1alpha1
      kind: Restore
      metadata:
        name: <app>
      spec:
        mover:
          privilegedMode: true
```

This is already wired for the apps that need it (esphome, qbittorrent, lazylibrarian, qui,
linkwarden, omada-controller, searxng, grimmory) — only relevant if adding a **new** non-1000
app to backups later. Without it, kopiur silently downgrades to the UID-1000 default rather than
erroring — looks identical to a working restore until you check ownership.

### If the app's PVC data doesn't match its database's expectations
A CSI populator restores bytes faithfully; it can't know a database has state that assumes the
disk's *prior* contents. Hit exactly this with immich: Postgres had folder-integrity marker files
recorded from before, the freshly-restored (genuinely empty, correctly so) disk had none, and
`immich-server` crash-looped until the 6 missing `.immich` marker files were manually recreated
(`thumbs`, `upload`, `backups`, `library`, `profile`, `encoded-video` — as UID 1000, via a debug
pod). Not a kopiur bug — would recur on any fresh volume paired with DB state that doesn't match,
including a real disk failure recovered from backup. If an app crash-loops post-restore with a
missing-file error and it has a separate database, check whether the DB is expecting disk state
the backup (correctly) doesn't have.

---

## 2. Restoring from an external/manual backup, not kopiur (✅ proven — thelounge)

Covers: you have a tarball or other out-of-band copy you want to load onto a PVC directly,
bypassing kopiur entirely (e.g. testing an old backup, or kopiur's own backup for that app is
empty/missing).

```
# Same suspend + scale-down as §1, steps 1-2. Then, instead of deleting the
# PVC, mount it directly via a debug pod running as root:
kubectl debug -n <namespace> --image=busybox:1.36 -it --target=<container> \
  --custom=<(echo '{"spec":{"containers":[{"name":"debugger","securityContext":{"runAsUser":0}}]}}') \
  <pod-name>
# (or a one-off Pod spec mounting the same PVC, if the original pod is already gone)

# Inside: extract the tarball onto the mounted volume.
tar -xzf /path/to/backup.tar.gz -C /data
```

**Check the app's actual runtime UID before assuming root.** Don't guess — check the image's own
Dockerfile (`USER` directive) if you can't exec into a running pod to check `id`/`whoami` (a pod
that's crash-looping on permission-denied can't be exec'd into meaningfully). thelounge's image
runs as `nobody`, not root, confirmed via its Dockerfile
(`github.com/home-operations/containers/blob/main/apps/thelounge/Dockerfile`) — the extracted
tarball needed `chown -R` to match before the app would start.

**BusyBox `tar` preserves ownership by default when run as root** — the opposite of GNU tar,
which needs an explicit `--same-owner`. BusyBox `tar` doesn't have a `--same-owner` flag at all
(unrecognized option) — if the tarball's stored UIDs don't match what the app expects, you still
need an explicit `chown -R <uid>:<gid>` pass after extracting, tar's default behavior won't fix
it for you.

```
chown -R <uid>:<gid> /data
```

Then resume as in §1 step 4 (`flux resume hr`), or just scale back up if you didn't suspend.

---

## 3. Database restore — CNPG / MariaDB (🟡 documented, not tested)

Not rehearsed live this session — the L2 (file) restore path got extensive real testing, the L1
(database) path did not. Treat this as a starting point, not a proven procedure. **Worth doing a
real drill against a throwaway CNPG cluster before trusting it under pressure.**

### CloudNativePG (Barman Cloud plugin, RGW-backed)
CNPG's standard pattern: point a **new** `Cluster`'s `.spec.bootstrap.recovery` at the existing
Barman object-store backup (same `barmanObjectStore`/plugin config, different cluster name), let
it recover from the base backup + WAL archive, then cut the app over. This does **not** overwrite
the broken cluster in place — it stands up a parallel one. See CNPG's own recovery docs for the
exact CR shape; this repo doesn't yet have a worked example checked into git.

### mariadb-operator (grimmory)
mariadb-operator's own `Restore` CR, pointed at a completed `Backup` CR
(`kubernetes/apps/media/grimmory/` has the `Backup` CR already; no `Restore` CR has ever been
created in this repo). Per the operator's docs this is a straightforward CR-apply, but unverified
against this cluster's actual RGW-backed `Backup` output.

---

## 4. Cluster-state — etcd / PKI (🟡 documented, not tested)

Not rehearsed. `kubernetes/apps/kube-system/etcd-backup/` produces a timestamped
`etcdctl snapshot save` + `/etc/kubernetes/pki` tarball in the `etcd-backup` RGW bucket every 6h,
now also synced to the NAS and B2 (see `backup-dr-plan.md` §2 cluster-state, §2 L3).

The **likely-preferred path for this cluster** given everything is GitOps: rebuild fresh
(`kubeadm init` on a clean CP node, `flux bootstrap` against this repo) rather than restoring
etcd in place, since every workload is re-appliable from git and L1/L2 backups restore the actual
data once the cluster exists again. The etcd/PKI snapshot exists for the narrower case of wanting
to preserve the exact prior cluster identity (issued certs, existing node membership) rather than
a clean rebuild — restoring it correctly (matching CA before rejoining nodes, `etcdctl snapshot
restore` semantics for a stacked-etcd kubeadm cluster) is real complexity that hasn't been walked
through end-to-end here. **This is the single biggest untested gap in the whole DR plan** — worth
a deliberate rehearsal (e.g. against a scratch VM cluster) rather than discovering the procedure
during an actual outage.

---

## 5. NAS is also gone — recovering from B2 alone (🟡 documented, not tested)

Covers the actual L3/site-loss scenario the off-site tier exists for: cluster **and** NAS both
gone, only the B2 buckets survive.

- **kopiur repo** (`kopiur-backups` bucket): a fresh `ClusterRepository`'s `backend` would need
  to point at B2 directly instead of NFS (kopiur supports S3-compatible backends natively per its
  own docs — not yet used anywhere in this repo, so the exact CR shape is unverified here).
  Alternatively, stand up a new NAS, `kopia repository sync-to` **from** B2 **to** the NAS to
  re-seed it, then reconnect the `ClusterRepository` to NFS as normal. Either way: never tested.
- **RGW-sourced DB/etcd backups** (`ceph-rgw-backups` bucket): same idea in reverse — `rclone
  sync` from `b2:ceph-rgw-backups/<bucket>` back down to a fresh NAS `/backups/rgw-sync/<bucket>`,
  or point Barman/mariadb-operator's restore path at B2 directly (both support S3-compatible
  targets natively, so this is likely a lower-friction path than round-tripping through the NAS).

---

## 6. Secrets — sops age key (owner task, not a restore procedure)

If the sops age private key is lost, every secret in this repo is permanently unrecoverable and
the cluster **cannot** be rebuilt from git alone. This isn't something Claude can verify or fix —
per this repo's own convention, sops/age material is never touched by anything but the repo
owner. **Confirm off-cluster backup in ≥2 places** (password manager + a second, physically
separate location) — tracked as still-open in `backup-dr-plan.md` §6/§8 item 2.

---

## Gaps this runbook exposes (candidates for the next backlog pass)

- No CNPG or MariaDB restore has ever actually been rehearsed against this cluster (§3).
- No full etcd/PKI cluster-rebuild has ever been rehearsed (§4) — the biggest real gap.
- No B2-only recovery (NAS also gone) has been rehearsed (§5).
- grimmory-bookdrop still has zero backup coverage regardless of restore path (see
  `migration-inventory.md` Backlog) — a restore procedure can't help data that was never backed
  up.
