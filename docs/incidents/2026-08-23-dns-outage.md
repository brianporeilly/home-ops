# Incident: cluster-wide DNS outage from a non-atomic policy promotion (2026-08-23)

## Summary

Merging PR #666+#676 (`docs/network-policy-plan.md` step 7 - promoting every staged Calico
policy to enforcing) broke DNS resolution for every namespace except `kube-system` itself, for
about 39 minutes (06:58Z-07:37Z). The promotion was designed to be atomic specifically to avoid
this failure mode, but landed as two independent Flux reconciles instead of one - a namespaced
half that applied in seconds, and a global half that got stuck behind an unrelated, bogus
dependency. The stuck half carried the one policy (`allow-dns-ingress`) needed to keep DNS
working. Flux could not self-heal: the outage broke its own ability to fetch git and resolve
in-cluster service names, which is what the fix needed to deploy through. Recovered via a manual
`kubectl apply` of the stuck manifests, bypassing Flux entirely.

## Timeline (UTC, 2026-08-23)

- **06:57:50** - `7f55b6a` merged to `main` (step 7 promotion + spegel-mirror widen, PR #666/#676).
- **06:58:02-03** - Root `cluster-apps` Kustomization (`flux-system`) reconciles fast, applies the
  new commit's `components/common` change across all 17 consuming namespaces - each gets a real
  `allow-same-namespace` `NetworkPolicy` (`selector: all()`, default tier), replacing the old
  `StagedNetworkPolicy` with the same name.
- **06:58:02-06** - DNS starts failing for every cross-namespace query (see Root Cause). This
  immediately begins breaking Flux's own reconciliation, since `source-controller`/
  `kustomize-controller`/`notification-controller` all need cross-namespace DNS lookups
  (`kube-system`-hosted CoreDNS) for their own routine operation.
- **06:58:01** - `kube-system/calico` Kustomization enters `DependencyNotReady`
  (`rook-ceph/rook-ceph-cluster` not ready) - see Root Cause for why this Kustomization was
  waiting on Ceph at all.
- **06:58:06 onward** - `rook-ceph-cluster` itself stuck: `kustomize-controller` can't download
  the git archive from `source-controller` (`dial tcp: lookup source-controller.flux-system...:
  i/o timeout`) - a same-namespace-as-the-client call that still has to resolve through
  `kube-system`'s CoreDNS, so it's caught by the same DNS breakage.
- **06:58 - ~07:37** - Cascading failure: 72-93 of 94 cluster Kustomizations (peaked around 72,
  fluctuated) show `DependencyNotReady`/`ArtifactFailed`, all downstream of `rook-ceph-cluster`
  directly or indirectly. `kube-system/calico-policies` (carrying `allow-dns-ingress`, the actual
  fix) never gets to reconcile - it depends on `calico`, which depends on `rook-ceph-cluster`.
- **~07:00 - 07:26** - Live investigation. Initially misattributed to OPNsense/upstream DNS
  instability (ruled out: user confirmed OPNsense CPU/load trivial; `ping 10.2.0.1` from both
  host and pod network on an affected node was 0% loss, sub-ms) and to a Flux reconcile-storm
  from a shared `components/common` file change (real secondary effect, but not sufficient
  explanation - user correctly pushed back that it didn't explain why this merge and not others).
- **07:31** - Root cause confirmed via a live Whisker/Goldmane flow trace showing the exact
  policy chain: `calico-system.cluster-dns` (Pass) -> default tier `EndOfTier: Deny`, triggered by
  `allow-same-namespace`, with the `pending` (staged) evaluation showing `allow-dns-ingress` would
  have Allowed it.
- **07:34** - Fix applied: `kubectl apply -f` the 16 `GlobalNetworkPolicy` manifests directly from
  the already-merged commit, bypassing Flux (which could not reach them itself).
- **07:36-07:38** - Full recovery confirmed: cross-namespace DNS resolves cleanly, `rook-ceph-
  cluster` reconciles successfully, `calico-policies` reconciles cleanly against the same objects
  (no conflict - Flux recognized them as already matching desired state), all 94/94
  Kustomizations reach `Ready`. User independently confirmed via cleared Watchdog alerts and a
  backlog of Slack notifications that had been blocked by the same DNS outage.

## Root cause

**Immediate mechanism:** the promotion's own design (see `docs/network-policy-plan.md` step 7)
explicitly required every staged policy to go enforcing in one atomic moment, because a
`selector: all()` policy going enforcing in Calico's `default` tier ends the permissive
per-namespace `kns.<namespace>` Profile fallback for every pod that selector claims - if the
*specific* policy that allows some traffic isn't live yet when the *claiming* policy is, that
traffic is denied at `EndOfTier` in the gap.

That gap is exactly what happened, cluster-wide, for DNS:

- `allow-same-namespace` (namespaced `NetworkPolicy`, `selector: all()`, default tier) is part of
  `components/common`, a Kustomize *Component* included via `components:` by every app namespace's
  `kustomization.yaml`. It gets applied directly by the **root** `cluster-apps` Kustomization
  (`flux-system`), which has no slow dependencies and reconciles in seconds.
- `allow-dns-ingress` (the `GlobalNetworkPolicy` meant to land in the same atomic moment,
  explicitly allowing DNS ingress cluster-wide) lives in `kube-system/calico-policies` - a
  **separate, independent** Flux `Kustomization` with its own `dependsOn` chain.

These two objects were never actually coupled by anything Flux enforces - "atomic" only held by
coincidence (both usually reconcile within seconds of each other under normal conditions). The
moment one side's dependency chain stalled, the promotion silently split into two, and the fast
half (which happened to include the policy that *claims* every `kube-system` pod, including
CoreDNS) landed alone.

**Why the slow half stalled:** `kube-system/calico-policies` depends on `kube-system/calico`,
which had `dependsOn: [envoy-gateway-config, rook-ceph-cluster]` - the unmodified default from
this repo's standard "new app" `ks.yaml` template (see `CLAUDE.md`). Calico is the CNI itself;
it has no genuine dependency on Ceph storage or Envoy Gateway (if anything, the real dependency
direction is the opposite - both of those need working pod networking to function at all). This
was very likely copied without adapting it when `calico`'s `ks.yaml` was first written.

**Why Flux couldn't self-heal:** once cross-namespace DNS broke, `source-controller` could no
longer resolve `github.com` (to fetch new commits) or even `source-controller.flux-system.svc...`
itself (kustomize-controller downloading the archive it just fetched - a same-namespace-as-caller
call that still has to resolve *through* `kube-system`'s CoreDNS, so still cross-namespace
relative to DNS itself, and still caught by the same deny). The one Kustomization carrying the
actual fix (`calico-policies`) was blocked behind `rook-ceph-cluster`, which was itself blocked by
the very outage the fix would have resolved. A genuine deadlock: GitOps couldn't deploy the fix to
the thing breaking GitOps's own ability to deploy it. Only a direct, Flux-bypassing `kubectl
apply` could break the cycle.

## What was fixed

1. **Immediate**: `kubectl apply -f` the 16 `GlobalNetworkPolicy` manifests directly from the
   already-reviewed, already-merged commit `7f55b6a` (`kubernetes/apps/kube-system/calico/
   policies/globalnetworkpolicy-*.yaml`) - nothing new, exactly what Flux would have applied
   itself. Flux later reconciled cleanly against the same objects with no conflict, once DNS
   recovered enough for it to run at all.
2. **Structural**: removed `dependsOn: [envoy-gateway-config, rook-ceph-cluster]` from
   `kube-system/calico`'s `ks.yaml` (this PR). Calico now has no dependencies, so
   `calico-policies` (and `calico-whisker-route`) can only ever be blocked by `calico`'s own
   (fast, self-contained) health - never by something unrelated downstream of it in the real
   dependency graph.

## What's still true and worth knowing for a future rebuild

- The **namespaced** half of any future staged-policy promotion (anything riding in
  `components/common`, applied by root `cluster-apps`) and the **Global** half (anything in
  `kube-system/calico-policies`) are still two independent Flux reconciles with no Flux-enforced
  ordering between them. Removing the bogus dependency makes both sides reconcile in a similarly
  fast window under normal conditions, which is why this specific incident won't recur *this way*
  - but it does not make the two sides atomic *by construction*. A different unrelated stall on
  either side could still reopen the same gap in principle.
- If doing another full cluster rebuild (bootstrapping from scratch) or re-promoting a large
  staged-policy batch: **do not assume "no error shown" means the promotion actually landed
  atomically.** Explicitly check `kubectl get globalnetworkpolicy.projectcalico.org` and
  `kubectl get networkpolicy.projectcalico.org -A` both show the expected objects *before*
  considering the promotion complete, and smoke-test a real cross-namespace DNS query (e.g. from
  a throwaway pod in a namespace that isn't `kube-system`) as part of the promotion checklist.
  This exact failure mode is easy to miss precisely because it can look like generic Flux/DNS
  flakiness rather than a policy gap - it took a live flow trace via Whisker to actually confirm
  it here, not the flux/kustomization status output.
- `kubectl get networkpolicy` (bare, unqualified) resolves to the **built-in Kubernetes**
  `networking.k8s.io` resource, not Calico's own `projectcalico.org` `NetworkPolicy` CRD - they
  share a Kind name but are entirely different objects. Always use
  `kubectl get networkpolicy.projectcalico.org` (or `caliconetworkpolicy`/`cnp`) when checking
  Calico's own policies; the bare form silently shows the wrong thing with no error, which cost
  real time during this investigation.
- Audited every other foundational (non-app) Kustomization for the same copy-pasted-template
  `dependsOn` mistake while writing this up: `calico` was the only offender. Every other genuinely
  foundational `kube-system` component (`kube-vip`, `spegel`, `csi-driver-nfs`, `reflector`,
  `reloader`, `snapshot-controller`, `metrics-server`, `kured`, `etcd-backup`) already has
  `dependsOn: []`; `envoy-gateway`, `external-secrets`, `cert-manager`, and the base `rook-ceph`
  operator all have minimal, legitimate dependencies (mostly just `prometheus-crds` for
  ServiceMonitor CRDs). Re-run this check after any future addition of a new foundational
  component, since a fresh copy-paste from the standard app template is exactly how this
  happened the first time.
