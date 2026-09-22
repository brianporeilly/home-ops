# OpenHands + agent-sandbox: isolated LLM agent PoC

Status: **Phase 1 landed, not yet deployed.** PR adds the manifests; still
needs a real Anthropic API key, a scratch-repo-scoped git token, and SOPS
encryption of both secret placeholders before it can reconcile for real -
see "Manual steps before this works" below.

## Why this exists

Goal: self-host [OpenHands](https://github.com/OpenHands/openhands)
(orchestrator + web UI) for interactive and headless LLM coding/task agents,
backed by a sandbox layer isolated enough that a misbehaving or malicious
tool call can't reach anything else in the cluster - without requiring
node-level changes (gVisor) for a first pass.

## Architecture

```
ai namespace (existing: llama-cpp, hermes-agent)
└── openhands          interactive web UI + headless mode, RUNTIME=process,
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

`OpenHands` itself runs with `RUNTIME=process` - no nested containers at
all. OpenHands's own docs label this mode "(unsafe, but fast)": it provides
no isolation of its own. That's intentional here - the Pod itself (hardened
securityContext + the egress policy above) is the isolation boundary, not
anything OpenHands provides internally.

## What's NOT built yet (Phase 2)

- **Dynamic per-session sandbox provisioning from OpenHands.** Today,
  OpenHands (RUNTIME=process) and `agent-sandbox` (headless `Sandbox`/
  `SandboxTemplate` CRs) are parallel, not integrated - OpenHands doesn't
  create `Sandbox` CRs on your behalf per conversation. Real integration
  needs a small service translating OpenHands's remote-runtime HTTP
  contract into `Sandbox` CRUD via `agent-sandbox`'s Go/Python SDK. That's
  actual software, needing its own source repo and image-build CI -
  deliberately not attempted in this PR.
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
