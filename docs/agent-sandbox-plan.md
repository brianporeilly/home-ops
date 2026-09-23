# OpenHands + agent-sandbox: isolated LLM agent PoC

Status: **Phase 1 merged and deployed (2026-09-22).** Eight real issues hit
across first boot, all fixed same day - see the "boot fix" sections below.
**Phase 2 written and locally validated (2026-09-22)** - RUNTIME=kubernetes
wired up, see "Phase 2: dynamic per-conversation sandboxes" below. Not yet
live-tested; expect this to take its own round of real-cluster boot fixes,
same as Phase 1 did.

## Why this exists

Goal: self-host [OpenHands](https://github.com/OpenHands/openhands)
(orchestrator + web UI) for interactive and headless LLM coding/task agents,
backed by a sandbox layer isolated enough that a misbehaving or malicious
tool call can't reach anything else in the cluster - without requiring
node-level changes (gVisor) for a first pass.

## Architecture

```
ai namespace (existing: llama-cpp, hermes-agent)
└── openhands          interactive web UI + headless mode, RUNTIME=kubernetes
                        (Phase 2 - was RUNTIME=local in Phase 1), Anthropic
                        Claude as default LLM, llama-cpp selectable as a
                        secondary provider via Settings once logged in

openhands-runtime namespace (new, Phase 2) - namespace + RBAC only, no
workloads of its own. openhands's KubernetesRuntime creates a Pod/Service/
PVC/Ingress here per conversation directly via the k8s API (no CRDs, no
controller - this is OpenHands's own first-party runtime backend, separate
from agent-sandbox below). See "Phase 2" below.

agent-sandbox-system namespace (rook-ceph-style operator + CR siblings)
├── agent-sandbox            controller - vendored kubernetes-sigs/agent-sandbox
│                             v1.0.2 release manifest (CRDs + Deployment + RBAC)
└── agent-sandbox-workloads  a SandboxTemplate + SandboxWarmPool for headless
                              coding-agent tasks + a scratch-repo-scoped git
                              credential - claim a Sandbox with a SandboxClaim
                              (see sandboxtemplate-coding-agent.yaml's header
                              comment for the exact command). Kept as a
                              separate, general-purpose mechanism (usable via
                              kubectl without OpenHands at all) - Phase 2
                              didn't fold this into openhands, see below.
```

Both namespaces run **enforcing** (not staged) egress `GlobalNetworkPolicy`
from day one - see
`kubernetes/apps/kube-system/calico/policies/globalnetworkpolicy-agent-sandbox-*.yaml`
and `globalnetworkpolicy-openhands-egress.yaml`. This is deliberately ahead
of the fleet's staged egress rollout (`docs/egress-policy-plan.md`): these
are brand-new namespaces with no legacy traffic to break, and a workload
class (agent with broad tool access) that specifically warrants
default-deny-egress from the start. Allowed: DNS, kube-apiserver (controller
pod only), HTTPS to the internet, and llama-cpp's ClusterIP for openhands.
Explicit `Deny` rules for the RFC1918 ranges sit ahead of the
internet-egress `Allow` in both workload-facing policies, closing the gap a
bare `0.0.0.0/0` would otherwise leave (that CIDR also covers this
cluster's own private ranges) - unlike the fleet's existing staged
internet-egress rules, which don't need that yet because they're not
enforcing.

## Why not the "obvious" options

- **`zparnold/openhands-kubernetes-remote-runtime`** implements OpenHands's
  own remote-runtime API contract, which would be the more direct
  integration. Ruled out for this PoC: no published container image (would
  need forking, building, and hosting on ghcr.io - a second source repo +
  CI pipeline, outside this GitOps repo's scope), and its subdomain-per-
  sandbox routing assumes an Ingress controller, which this cluster doesn't
  run (Envoy Gateway speaks Gateway API, not classic Ingress).
- **Docker-in-Docker / `docker.sock` mount** (OpenHands's own documented
  default) was ruled out on purpose - a socket equivalent to host root has
  no place in this cluster.
- **gVisor** was ruled out for v1 by explicit choice: its DaemonSet
  installer reboots every node it touches, real blast radius for a PoC.
  Pod Security (non-root, dropped caps, seccomp) + the NetworkPolicies
  above stand in for it. `kubernetes-sigs/agent-sandbox`'s `Sandbox`/
  `SandboxTemplate` CRDs explicitly support adding a `RuntimeClass` later
  with zero other changes - see "Phase 2" below.

`OpenHands` itself runs with `RUNTIME=local` - no nested containers at
all. OpenHands's own docs label this mode "(unsafe, but fast)": it provides
no isolation of its own. That's intentional here - the Pod itself (hardened
securityContext + the egress policy above) is the isolation boundary, not
anything OpenHands provides internally.

## First-boot crash: wrong UID (found live, fixed same day, 2026-09-22)

First deploy crash-looped: `exec: "/app/entrypoint.sh": stat /app/entrypoint.sh:
permission denied`. Pulled the image's actual source
(`containers/app/{Dockerfile,entrypoint.sh}` at the `0.59.0` tag) to find out
why:

- `entrypoint.sh` is baked in `--chown=openhands:openhands --chmod=770` (UID/GID
  42420) - not readable/executable under this repo's usual `runAsUser: 1000`
  default (that default exists for NAS file access elsewhere in this repo,
  irrelevant to this app).
- Separately, `entrypoint.sh`'s own setup logic hard-exits unless `id -u` is
  0, and only drops to a non-root `enduser` via a path that reads
  `/var/run/docker.sock`'s group id - unusable here since `RUNTIME=local`
  means no docker socket is ever mounted, on purpose.
- The fix isn't "run as root": `entrypoint.sh` also honors `NO_SETUP=true`,
  which skips all of that setup logic - including the root check - before it
  ever runs, and just execs the image's own `CMD`
  (`uvicorn openhands.server.listen:app`) directly. Paired with
  `runAsUser: 42420` (the image's real non-root user, matched exactly), the
  kernel can exec `entrypoint.sh` as its owner and the app never needs root
  at all - see `kubernetes/apps/ai/openhands/app/helmrelease.yaml`'s inline
  comments for the full detail.

So this ended up genuinely non-root, not merely root-with-capabilities-dropped
- better than the `hermes-agent` precedent this was initially going to copy.
The Pod/NetworkPolicy boundary in
`globalnetworkpolicy-openhands-egress.yaml` still carries the real isolation
weight (RUNTIME=local itself provides none, regardless of UID - OpenHands's
own docs call it "unsafe, but fast"), but the container process itself is no
longer part of that risk either.

## Second boot fix: file_store_path (2026-09-22)

Fixed the UID above, then hit `PermissionError: '/.openhands/.jwt_secret'`.
OpenHands's `file_store_path` config defaults to `~/.openhands`; `~` isn't
resolving to a real home directory for UID 42420 in this container, so it
lands on the unwritable root filesystem instead of the PVC. Set
`FILE_STORE_PATH` (confirmed against `openhands/core/config/utils.py`'s
env-var mapping - top-level config fields map straight to their uppercased
name, same as `RUNTIME`) to a path under `/.openhands-state`.

## Third boot fix: RUNTIME value (2026-09-22)

Fixed `file_store_path` above, then hit `ValueError: Runtime process not
supported, known are: dict_keys(['eventstream', 'docker', 'remote', 'local',
'kubernetes', 'cli'])` - `process` was never a real value for this OpenHands
version; the docs page that suggested it was describing the UI label
("Process"), not the config value. Correct value is `local`
(`openhands/runtime/__init__.py`'s `LocalRuntime`).

That registry also surfaced a first-party `kubernetes` runtime
(`openhands/runtime/impl/kubernetes/kubernetes_runtime.py`) - OpenHands
creates sandbox Pods/Services directly via the k8s API itself, no
`agent-sandbox` or custom glue service needed. Worth real evaluation for
Phase 2 below; the one confirmed blocker so far is the same one that ruled
out zparnold's project - it provisions a `V1Ingress` per sandbox, and this
cluster has no Ingress controller (Envoy Gateway speaks Gateway API only).

## Fourth boot fix: tmux missing from the image (2026-09-22)

Fixed the `RUNTIME` value above, then hit `ValueError: tmux is not properly
installed or available on the path.` - `LocalRuntime` shells out to a real
`tmux` binary via `libtmux` for every command the agent runs, not just for
this startup check. Confirmed in `containers/app/Dockerfile`: the published
image genuinely never installs it.

Chose an `initContainers.install-tmux` that `apt-get install`s it fresh each
boot and copies the binary + its shared libs into two emptyDirs shared with
the main container, over building a custom derivative image - no new
source repo/CI needed, stays inside this GitOps repo. Tradeoff accepted: a
Debian-mirror network dependency and a few seconds added to every pod
(re)start, and `globalnetworkpolicy-openhands-egress.yaml` now also allows
port 80 (Calico enforces per-Pod, not per-container, so this widens the main
container's own egress too, not just the initContainer's).

## Fifth boot fix: our own tmux fix shadowed the real Python (2026-09-22)

The tmux fix above originally mounted its shared emptyDirs at `/usr/local/bin`
and `/usr/local/lib/tmux-deps`, reasoning `/usr/local/bin` would "already be
on PATH." It is - but it's also where this image's real `python3.13` lives
(`/app/.venv/bin/python3` resolves there via symlink, confirmed by exec'ing
into the actual pinned image). Mounting an emptyDir over an existing,
non-empty directory doesn't merge with it - it fully shadows the image's own
contents at that path for as long as the volume's mounted, so the real
interpreter became unreachable and every process in the container failed:
`/app/.venv/bin/uvicorn: cannot execute: required file not found`.

Moved both mounts to `/opt/tmux/{bin,lib}` - confirmed empty/unused in the
real image before adding anything there - and stopped relying on "already on
PATH": `PATH` is now set explicitly to the real baked-in value (confirmed
live against the exact pinned image/digest) plus `/opt/tmux/bin` prepended.
General lesson, not just for this app: never mount a volume at a path that
already has content in the image without checking first - `kubectl run
--rm -it <same-pinned-image> -- sh` is cheap and turns a guess into a fact.

## Sixth fix: disabled the bundled browser (2026-09-22)

Pod stopped crash-looping after the fifth fix, but never went `Ready`
(startup probe: `connection refused` on 3000 - app was hung, not just slow).
Logs showed a background subprocess failing:
`playwright._impl._errors.Error: BrowserType.launch: EACCES: permission
denied, mkdir '/workspace'`. `enable_browser` defaults `true` and spawns an
in-process Chromium (via `playwright`) as part of startup; the parent
appears to block waiting on it.

Set `ENABLE_BROWSER: "false"` rather than chase this further - fixing the
`/workspace` permission would likely only surface the next problem
(headless Chromium's system-library chain, which this slim image almost
certainly doesn't have), and this namespace already has a dedicated,
working browser pattern (`hermes-agent`'s `sockpuppetbrowser` CDP sidecar)
rather than bundling a browser into the app itself. If the agent UI's
`browser` tool turns out to matter for real usage, wiring OpenHands at a
CDP endpoint (same shape as `hermes-agent`'s `browser.cdp_url`) is the
follow-up, not re-enabling the bundled one.

## Seventh fix: su openhands - fails, we're not root (2026-09-22)

With Settings configured (see the "expected first-run UX" note above) and a
real 404 reaching the frontend again (separate cluster-wide fix - see
`kubernetes/apps/network/envoy-gateway/config/envoy.yaml`'s own comment,
not duplicated here), starting a conversation still hung at "Starting
runtime." Logs showed the actual failure a few lines in:
`Password: su: Authentication failure`, then `_init_bash_commands` raising
`AssertionError` right after - the agent's shell tool never got a working
bash session.

`openhands/runtime/utils/bash.py`'s `BashSession.initialize()` runs
`su {username} -` to start that shell whenever `SU_TO_USER` (env var,
defaults `true`) is set AND `self.username` is `RUNTIME_USERNAME`, `root`,
**or the literal string `'openhands'`** - hardcoded, not derived from our
`--username` flag. Since we're already running as that exact user via
`securityContext` (not root), `su` has no password to authenticate with and
was never going to succeed - it's solving a problem (become the right user)
that Kubernetes already solved a different way. Set `SU_TO_USER: "false"`
to skip it and run bash directly as the current (already correct) user.

## Eighth fix: host.docker.internal doesn't exist here (2026-09-22)

`SU_TO_USER=false` didn't fully fix it - still hung at "Starting runtime."
The actual clue was in an earlier log line that looked benign at first:
`[runtime ...] Waiting for server to become ready at
http://host.docker.internal:NNNNN...` - `host.docker.internal` is Docker
Desktop-specific DNS magic for reaching the host from inside a container;
it has no CoreDNS record and never will in a Kubernetes pod. Matches the
very first `httpx.ConnectError: [Errno -2] Name or service not known` seen
back when tmux was still broken - not a stale/unrelated error, the same
live bug the whole time, just masked by louder crashes until now.

Root cause confirmed in `containers/app/Dockerfile`:
`ENV SANDBOX_LOCAL_RUNTIME_URL=http://host.docker.internal` - baked in for
upstream's documented `docker run --add-host host.docker.internal:host-gateway`
deployment style. The actual code default (`sandbox_config.py`) is
`http://localhost`, which is what we need: the `action_execution_server`
subprocess `LocalRuntime` spawns runs in this same container/network
namespace, not a separate host. Set
`SANDBOX_LOCAL_RUNTIME_URL: "http://localhost"` to override the image's
baked default back to the code's own actual default.

Pulled the image's full `ENV` block at this point (`grep '^ENV '
containers/app/Dockerfile`) to check for other baked defaults fighting our
config in the same way, rather than keep finding them one crash at a time -
nothing else stood out as live-affecting.

With OpenHands working end-to-end (conversation started, agent responded
and ran commands in its own container), attention turned to validating
`agent-sandbox` before starting Phase 2 - tested live (2026-09-22), cleaned
up after. Found two real gaps in what Phase 1 claimed worked:

- **`SandboxTemplate` was never actually claimable.** `Sandbox` has no
  `templateRef` field, and `SandboxClaim` requires a `warmPoolRef`, not a
  template ref - the instantiation instructions originally written in
  `sandboxtemplate-coding-agent.yaml`'s header comment didn't work at all.
  Added `sandboxwarmpool-coding-agent.yaml` (`replicas: 1` - a WarmPool
  pre-provisions ahead of demand, not scale-from-zero on claim, so 0 would
  mean nothing ever exists to claim) and corrected the instructions to
  claim from it. Confirmed live: claiming adopts the pre-warmed Sandbox
  immediately, and the pool self-heals by creating a replacement.
- **The `claude-code` CLI base image has no `git`.** Confirmed live
  (`which git` → nothing). Tried Microsoft's `devcontainers/base:ubuntu-24.04`
  next (git + a pre-baked non-root `vscode` user at UID 1000, matching this
  repo's convention) but the user preferred to avoid a vendor-branded image
  for what's meant to be a placeholder - landed on plain
  `docker.io/library/buildpack-deps:noble-scm` (Docker Official Image,
  Ubuntu 24.04, scm variant): confirmed live to have git 2.43.0 and,
  usefully, a real `ubuntu` user already at UID 1000 with `HOME` resolved
  correctly (no repeat of the OpenHands UID/HOME class of bug). No language
  runtime - intentional, this is the "something pre-built that works today"
  stand-in, not the destination. A purpose-built Fedora-based sandbox image
  is the planned real replacement, once real usage shows what it actually
  needs to contain.

## Known issue, not chased down: OpenHands git clone (2026-09-22)

Cloning a GitHub repo through OpenHands's own UI didn't work - the agent
reported it appeared to be in the OpenHands app directory instead of the
workspace. Not investigated: plausibly `git` missing from the OpenHands
image itself (same class of gap as `agent-sandbox`'s original base image),
or a `WORKSPACE_BASE`-vs-actual-cwd mismatch given that env var's own
deprecation warning (see the env block in
`kubernetes/apps/ai/openhands/app/helmrelease.yaml`). Deliberately not
chased tonight - agreed to move to Phase 2 instead once the core
conversation loop worked. Worth a `which git` check inside a running
`openhands` pod as the first step whenever this gets picked back up.

## Phase 2: dynamic per-conversation sandboxes (2026-09-22)

Chose path (b) from the original Phase 2 writeup below: OpenHands's own
first-party `RUNTIME=kubernetes` backend
(`openhands/runtime/impl/kubernetes/kubernetes_runtime.py`), not a custom
glue service translating to `agent-sandbox` `Sandbox` CRs. No new source
repo/CI, and the one blocker the original writeup flagged turned out not to
be one - see below.

**The "Ingress-per-sandbox" blocker wasn't real.** `KubernetesRuntime`
unconditionally creates a per-conversation `networking.k8s.io/v1 Ingress`
(for VSCode-in-browser access) alongside the Pod/Service/PVC, and this
cluster's only ingress controller (Envoy Gateway) speaks Gateway API
(`HTTPRoute`), not classic `Ingress` - the concern was that this would
error out and block every conversation from starting. Confirmed live
(read-only `kubectl get ingressclass`, `kubectl get validatingwebhook...
-o json` scan) before writing any of this: no `IngressClass` exists and no
admission webhook targets `Ingress` resources in this cluster, so the
`create_namespaced_ingress` call the runtime makes still succeeds - it just
produces an object nothing ever reconciles. Net effect: the conversation/
shell/editor loop works, VSCode-in-browser access is a silent no-op. Traded
off deliberately rather than chased further (see "Known gaps" below).

**What changed:**
- `kubernetes/apps/openhands-runtime/` (new top-level category = new
  namespace `openhands-runtime`, sibling to `ai`) - namespace + RBAC only,
  no workloads of its own. `rbac/app/rbac.yaml` grants the `openhands`
  ServiceAccount (created in the `ai` namespace by
  `helmrelease.yaml`'s `serviceAccount.openhands` + each controller's
  `serviceAccount.identifier: openhands`) a namespaced `Role` to create/
  list/delete `pods`, `services`, `persistentvolumeclaims`, and
  `ingresses.networking.k8s.io` - exactly what `_init_k8s_resources`/
  `_cleanup_k8s_resources` in `kubernetes_runtime.py` call. Cross-namespace
  `RoleBinding` (subject in `ai`, `Role` in `openhands-runtime`) - kept
  separate rather than granting this in `openhands`'s own namespace so the
  blast radius of "what can spawn/delete pods" stays scoped to one
  namespace, same reasoning as `agent-sandbox-system`.
- `kubernetes/apps/ai/openhands/app/helmrelease.yaml`:
  - `RUNTIME: "kubernetes"` (was `"local"`).
  - Added `KUBERNETES_NAMESPACE`, `KUBERNETES_PVC_STORAGE_CLASS`,
    `KUBERNETES_PVC_STORAGE_SIZE`, `KUBERNETES_RESOURCE_CPU_REQUEST`,
    `KUBERNETES_RESOURCE_MEMORY_REQUEST`, `KUBERNETES_RESOURCE_MEMORY_LIMIT`
    - all map onto `KubernetesConfig` fields via `load_from_env`'s generic
    `<field>_<name>` prefix walk (confirmed against `utils.py` and
    `kubernetes_config.py` at the 0.59.0 tag - `cfg.kubernetes` is a real
    `KubernetesConfig()` instance by default, not `None`, so it's walked
    like any other nested config section; no `config.toml` file needed).
  - Added `SANDBOX_RUNTIME_CONTAINER_IMAGE` pointed at upstream's
    pre-built `ghcr.io/all-hands-ai/runtime:0.59-nikolaik` (digest-pinned,
    confirmed to exist for `amd64` via the ghcr.io v2 manifest API).
    Without this, `KubernetesRuntime.pod_image` falls back to the bare
    `nikolaik/python-nodejs` base image - fine for the Docker runtime
    (which builds `action_execution_server` into it first), but
    `KubernetesRuntime` has no build step and uses `pod_image` as-is, so
    the bare base image would boot a pod with no OpenHands server in it at
    all.
  - `controllers.openhands.serviceAccount.identifier` +
    `pod.automountServiceAccountToken: true` + top-level
    `serviceAccount.openhands: {}` - the in-cluster k8s client
    (`config.load_incluster_config()`) needs a mounted SA token, which the
    chart disables by default. Confirmed the resulting ServiceAccount name
    (`openhands`, not a suffixed variant) via `helm template` against the
    pinned chart version before relying on it for the RoleBinding subject.
  - Removed all of Phase 1's `RUNTIME=local`-only scaffolding, now dead
    weight: `initContainers.install-tmux` and its `tmux-bin`/`tmux-lib`
    `persistence` entries (tmux/libtmux only mattered when the bash tool
    ran in *this* container - it now runs in the spawned runtime pod,
    whose pre-built image already has tmux), the `PATH`/`LD_LIBRARY_PATH`
    overrides that existed only to surface that tmux install,
    `SU_TO_USER`/`SANDBOX_LOCAL_RUNTIME_URL` (both `LocalRuntime`-specific
    bugs), `WORKSPACE_BASE` (already-deprecated, `LocalRuntime`-specific
    mount path), and `ENABLE_BROWSER: "false"` (was working around an
    in-*this*-container headless Chromium under `LocalRuntime` - left
    **unset** now, defaulting to enabled, since the browser tool runs in
    the spawned runtime pod's own filesystem instead; genuinely untested,
    first thing to check if a conversation hangs on startup again).
  - Kept, unchanged: `pod.securityContext` (UID 42420 + `NO_SETUP: "true"`,
    needed to exec `entrypoint.sh` at all, unrelated to the runtime
    backend), `FILE_STORE_PATH`, and the probes/persistence for
    `/.openhands-state` - all about this server process itself, not how
    agent actions execute.
- `kubernetes/apps/kube-system/calico/policies/`:
  `globalnetworkpolicy-openhands-egress.yaml` gained an `Allow` to the
  three CP node IPs on 6443 (kubeadm's stacked etcd/apiserver run as
  hostNetwork static pods, so their identity is the node IP, same pattern
  as `globalnetworkpolicy-agent-sandbox-controller-egress.yaml`) - the
  `openhands` pod is now a k8s API client. Two new files:
  `globalnetworkpolicy-openhands-runtime-egress.yaml` (DNS + HTTPS-only
  egress for the spawned sandbox pods, enforcing from day one, same
  shape/rationale as `...-agent-sandbox-workloads-egress.yaml` - selector
  matches `app: openhands-runtime`, the label `KubernetesRuntime` itself
  hardcodes on every pod it creates, confirmed against source, not
  something we control) and
  `globalnetworkpolicy-openhands-to-runtime-sandbox.yaml` (cross-namespace
  ingress allow, `ai` → `openhands-runtime` port 8080 only - the
  same-namespace-only default doesn't cover this since the two live in
  different namespaces on purpose).
- `kubernetes/apps/ai/openhands/ks.yaml` gained a `dependsOn` on the new
  `openhands-runtime-rbac` Kustomization - not a hard boot requirement
  (the k8s calls only happen lazily per-conversation), just avoids a race
  on first real use right after a fresh install.

**Known gaps, not chased further this round:**
- **VSCode-in-browser is inert** (see the Ingress note above) - the
  execution-server/shell/editor/browser-tool loop doesn't depend on it,
  but a human clicking "Open VSCode" in the UI will hit a dead link. Real
  fix would be something that turns each per-conversation Ingress into a
  Gateway API `HTTPRoute` (a small controller, or patching
  `kubernetes_runtime.py` directly) - not attempted here.
- **Stale PVCs accumulate.** `KubernetesRuntime.close()` only deletes the
  Pod/Services (not the PVC) unless the conversation is explicitly deleted
  from the UI (`remove_pvc=True` only on that path and on process
  shutdown). Abandoned/crashed conversations leave a `ceph-block` PVC
  behind in `openhands-runtime` with no automatic cleanup. Worth a
  periodic `kubectl get pvc -n openhands-runtime` check until/unless this
  gets its own CronJob.
- **Untested end-to-end.** Everything above passed `helm template` (against
  the exact pinned chart), `kubectl kustomize` per changed directory, and
  a full `flux build kustomization cluster-apps --strict-substitute`
  locally - but none of that exercises the actual runtime behavior (a
  real conversation spawning a real pod, the RBAC actually being
  sufficient, the egress policy actually being enough for `pip`/`npm`/
  `git`). Phase 1 needed eight live-debugged boot fixes before it worked;
  expect this to need its own round the same way. First things to check
  when picking this back up live: does the spawned Pod reach `Running`,
  does `kubectl logs` on the openhands pod show a successful `_init_k8s_
  resources`, and does `ENABLE_BROWSER` (now unset) cause the same
  startup hang Phase 1's sixth fix found.
- **`hermes-agent` removal and its `sockpuppetbrowser` sidecar are
  deliberately out of scope here** - planned as a separate PR (removing an
  unrelated app shouldn't ride on this change). If Phase 2's browser tool
  (now enabled, untested per above) turns out not to work reliably inside
  the spawned runtime pod, the fallback is a dedicated `sockpuppetbrowser`
  CDP sidecar for `openhands`/`agent-sandbox` specifically - not
  hermes-agent's instance, which is going away, and not shared with
  changedetection's either (see that instance's own capacity-isolation
  rationale in `hermes-agent/app/helmrelease.yaml`). Not built yet;
  contingent on what live testing actually shows.

## What was considered and not built (from the original Phase 2 writeup)

- **A custom glue service translating OpenHands's remote-runtime HTTP
  contract into `agent-sandbox` `Sandbox` CRUD** (path (a) above) - ruled
  out once path (b) turned out not to need it: real software, its own
  source repo and image-build CI, for no benefit over OpenHands's own
  built-in `RUNTIME=kubernetes` backend.
- **gVisor / any `RuntimeClass`.** Add `runtimeClassName` to the
  `SandboxTemplate`'s `podTemplate.spec` once it's worth the node-level
  installer's blast radius - scope it to a single labeled node first, not
  fleet-wide, given the reboot-every-node-it-touches installer behavior.
- **Promoting the fleet-wide staged egress rollout.** Unrelated to this
  work - only `agent-sandbox-system`, `ai`, and (as of Phase 2)
  `openhands-runtime` go enforcing here.

## Manual steps before this works

1. Create a fine-grained GitHub PAT or deploy key scoped **only** to your
   scratch/throwaway repo(s) - never this home-ops repo, never broad org
   access.
2. Have an `ANTHROPIC_API_KEY` ready.
3. Fill in and `sops --encrypt --in-place` both:
   - `kubernetes/apps/ai/openhands/app/secret.yaml`
   - `kubernetes/apps/agent-sandbox/agent-sandbox/workloads/secret.yaml`

## Verification

- `kustomize build` each new/changed directory locally before merging
- After merge: `flux get kustomizations -A` to confirm `agent-sandbox`,
  `agent-sandbox-workloads`, `openhands`, and (Phase 2)
  `openhands-runtime-rbac` all reconcile;
  `kubectl get sandboxtemplate -n agent-sandbox-system`
- Instantiate one `Sandbox` from the `coding-agent` template (see the
  comment atop `sandboxtemplate-coding-agent.yaml` for the exact command),
  confirm it starts, can reach the internet/git remote, and cannot reach
  rook-ceph or any other app namespace
- Log into `openhands.internal.oreillys.io` through Authentik as an
  `infra-users` member, run one small real task against a scratch repo
  end-to-end (clone → edit → push to a branch)
- Phase 2 specifically: while that task runs, `kubectl get pods -n
  openhands-runtime -w` to confirm a real `openhands-runtime-<sid>` pod
  gets created and reaches `Running`/`Ready`; `kubectl logs -n ai
  deploy/openhands` for `_init_k8s_resources` / RBAC-denied errors if it
  doesn't; confirm the pod cannot reach rook-ceph or any other app
  namespace (same check as the `agent-sandbox` one above) but can reach
  the internet for `git clone`/`pip`/`npm`; delete the conversation from
  the UI afterward and confirm its PVC is actually gone (see "stale PVCs"
  above)
