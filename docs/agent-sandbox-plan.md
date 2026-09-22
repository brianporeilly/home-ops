# OpenHands + agent-sandbox: isolated LLM agent PoC

Status: **Phase 1 merged and deployed (2026-09-22).** Eight real issues hit
across first boot, all fixed same day - see the "boot fix" sections below.

## Why this exists

Goal: self-host [OpenHands](https://github.com/OpenHands/openhands)
(orchestrator + web UI) for interactive and headless LLM coding/task agents,
backed by a sandbox layer isolated enough that a misbehaving or malicious
tool call can't reach anything else in the cluster - without requiring
node-level changes (gVisor) for a first pass.

## Architecture

```
ai namespace (existing: llama-cpp, hermes-agent)
└── openhands          interactive web UI + headless mode, RUNTIME=local,
                        own Pod is the isolation boundary, Anthropic Claude
                        as default LLM, llama-cpp selectable as a secondary
                        provider via Settings once logged in

agent-sandbox-system namespace (new, rook-ceph-style operator + CR siblings)
├── agent-sandbox            controller - vendored kubernetes-sigs/agent-sandbox
│                             v1.0.2 release manifest (CRDs + Deployment + RBAC)
└── agent-sandbox-workloads  a SandboxTemplate for headless coding-agent
                              tasks + a scratch-repo-scoped git credential
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

## What's NOT built yet (Phase 2)

- **Dynamic per-session sandbox provisioning from OpenHands.** Today,
  OpenHands (RUNTIME=local) and `agent-sandbox` (headless `Sandbox`/
  `SandboxTemplate` CRs) are parallel, not integrated - OpenHands doesn't
  create `Sandbox` CRs on your behalf per conversation. Two paths, both
  unevaluated in depth yet: (a) a small service translating OpenHands's
  remote-runtime HTTP contract into `Sandbox` CRUD via `agent-sandbox`'s
  Go/Python SDK - real software, its own source repo and image-build CI; or
  (b) OpenHands's own `RUNTIME=kubernetes` (see above) - no new software,
  but needs its Ingress-per-sandbox behavior worked around or patched
  first. (b) is the more promising lead given it needs no separate
  source repo, deliberately not attempted in this PR.
- **gVisor / any `RuntimeClass`.** Add `runtimeClassName` to the
  `SandboxTemplate`'s `podTemplate.spec` once it's worth the node-level
  installer's blast radius - scope it to a single labeled node first, not
  fleet-wide, given the reboot-every-node-it-touches installer behavior.
- **Promoting the fleet-wide staged egress rollout.** Unrelated to this
  work - only the two new namespaces above go enforcing here.

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
  `agent-sandbox-workloads`, and `openhands` all reconcile;
  `kubectl get sandboxtemplate -n agent-sandbox-system`
- Instantiate one `Sandbox` from the `coding-agent` template (see the
  comment atop `sandboxtemplate-coding-agent.yaml` for the exact command),
  confirm it starts, can reach the internet/git remote, and cannot reach
  rook-ceph or any other app namespace
- Log into `openhands.internal.oreillys.io` through Authentik as an
  `infra-users` member, run one small real task against a scratch repo
  end-to-end (clone → edit → push to a branch)
