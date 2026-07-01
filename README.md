# home-ops

[![Flux Local](https://github.com/brianporeilly/home-ops/actions/workflows/flux-local.yaml/badge.svg)](https://github.com/brianporeilly/home-ops/actions/workflows/flux-local.yaml)

FluxCD-managed Kubernetes cluster running applications defined via the
[bjw-s app-template](https://github.com/bjw-s-labs/helm-charts) Helm chart.
Secrets encrypted with SOPS (age). Rook/Ceph for storage. Envoy Gateway (Gateway API) for ingress.

See [AGENTS.md](AGENTS.md) for full repo structure and conventions.
