#!/usr/bin/env python3
"""Generate FluxCD app scaffolding for the bjw-s app-template Helm chart."""

import argparse
import os
import sys
from pathlib import Path

from jinja2 import Environment, FileSystemLoader

REPO_ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_DIR = REPO_ROOT / "templates" / "app-template"
APPS_DIR = REPO_ROOT / "kubernetes" / "apps"

FILES = [
    ("ks.yaml", "ks.yaml.j2"),
    ("app/kustomization.yaml", "app/kustomization.yaml.j2"),
    ("app/ocirepository.yaml", "app/ocirepository.yaml.j2"),
    ("app/helmrelease.yaml", "app/helmrelease.yaml.j2"),
]


def parse_volume(raw: str) -> dict:
    parts = raw.split(":")
    name = parts[0]
    size = parts[1] if len(parts) > 1 else "1Gi"
    mount_path = parts[2] if len(parts) > 2 else f"/{name}"
    sub_path = parts[3] if len(parts) > 3 else None
    is_empty_dir = size.lower() in ("emptydir", "tmpfs")
    return {
        "name": name,
        "size": size,
        "mount_path": mount_path,
        "sub_path": sub_path,
        "is_empty_dir": is_empty_dir,
        "advanced_mounts": sub_path is not None or is_empty_dir,
    }


def parse_env(raw: str) -> tuple:
    key, val = raw.split("=", 1)
    return key, val


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate FluxCD app scaffolding using bjw-s app-template"
    )
    parser.add_argument("-n", "--namespace", required=True, help="Namespace/category (e.g. media, home)")
    parser.add_argument("-a", "--name", required=True, help="App name (kebab-case)")
    parser.add_argument("-i", "--image", required=True, help="Container image repository")
    parser.add_argument("-t", "--tag", required=True, help="Image tag (e.g. 10.10.7)")
    parser.add_argument("-d", "--digest", required=True, help="Image SHA256 digest (hex)")
    parser.add_argument("-H", "--hostname", required=True, help="Route hostname (e.g. app.internal.oreillys.io)")
    parser.add_argument(
        "-v", "--volume",
        action="append",
        dest="volumes",
        default=[],
        help="Volume in format name:size:mountPath[:subPath]  (size=emptyDir for tmpfs)",
    )
    parser.add_argument("-p", "--port", type=int, default=8080, help="Container port (default 8080)")
    parser.add_argument("--probe-path", default="/health", help="HTTP health check path (use 'none' to skip probes)")
    parser.add_argument("--startup-probe", action="store_true", help="Add a startup probe (30 retries)")
    parser.add_argument("-e", "--env", action="append", dest="env_vars", default=[], help="Extra env vars KEY=VALUE")
    parser.add_argument("--route-type", choices=["internal", "external"], default="internal", help="Route gateway")
    parser.add_argument("--add-secret", action="store_true", help="Add secret.yaml and envFrom reference")
    parser.add_argument("--no-reloader", action="store_true", help="Skip reloader annotation")
    parser.add_argument("--chart-version", default="5.1.0", help="app-template chart version (default 5.1.0)")
    parser.add_argument("--memory-limit", default="1Gi", help="Memory limit (default 1Gi)")
    parser.add_argument("--memory-request", default="100Mi", help="Memory request (default 100Mi)")
    parser.add_argument("--cpu-request", default="100m", help="CPU request (default 100m)")
    parser.add_argument("--dry-run", action="store_true", help="Print files to stdout instead of writing")
    parser.add_argument("--force", action="store_true", help="Overwrite existing files")
    args = parser.parse_args()

    if not TEMPLATE_DIR.exists():
        print(f"Error: template directory not found: {TEMPLATE_DIR}", file=sys.stderr)
        sys.exit(1)

    env = Environment(loader=FileSystemLoader(str(TEMPLATE_DIR)), trim_blocks=True, lstrip_blocks=True)

    digest = args.digest.removeprefix("sha256:")
    image_tag = f"{args.tag}@sha256:{digest}"
    gateway_name = f"envoy-{args.route_type}"
    has_reloader = not args.no_reloader

    volumes = [parse_volume(v) for v in args.volumes]
    env_vars = dict(parse_env(e) for e in args.env_vars)
    controller_name = args.name

    context = {
        "namespace": args.namespace,
        "app_name": args.name,
        "controller_name": controller_name,
        "image_repository": args.image,
        "image_tag": image_tag,
        "hostname": args.hostname,
        "port": args.port,
        "probe_path": None if args.probe_path.lower() == "none" else args.probe_path,
        "startup_probe": args.startup_probe,
        "chart_version": args.chart_version,
        "route_type": args.route_type,
        "gateway_name": gateway_name,
        "has_secret": args.add_secret,
        "has_reloader": has_reloader,
        "volumes": volumes,
        "env_vars": env_vars,
        "memory_limit": args.memory_limit,
        "memory_request": args.memory_request,
        "cpu_request": args.cpu_request,
    }

    app_dir = APPS_DIR / args.namespace / args.name / "app"

    print(f"  namespace: {args.namespace}")
    print(f"  app name:  {args.name}")
    print(f"  image:     {args.image}:{image_tag}")
    print(f"  hostname:  {args.hostname}")
    print(f"  volumes:   {[v['name'] for v in volumes] if volumes else '(none)'}")
    print()

    for output_path, template_name in FILES:
        template = env.get_template(template_name)
        rendered = template.render(**context)

        if args.dry_run:
            print(f"--- {output_path} ---")
            print(rendered)
            print()
            continue

        target = app_dir.parent if output_path.startswith("app/") else app_dir.parent / output_path
        if output_path.startswith("app/"):
            target = app_dir / output_path[len("app/"):]
        else:
            target = app_dir.parent / output_path

        if target.exists() and not args.force:
            print(f"SKIP  {target}  (exists, use --force to overwrite)", file=sys.stderr)
            continue

        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(rendered)
        print(f"WROTE {target}")

    if not args.dry_run:
        ns_kustomization = APPS_DIR / args.namespace / "kustomization.yaml"
        if ns_kustomization.exists():
            print()
            print(f"NEXT: add to {ns_kustomization}:")
            print(f"  resources:")
            print(f"    - ./{args.name}/ks.yaml")
        if args.add_secret:
            print()
            print(f"NEXT: create and encrypt {app_dir}/secret.yaml:")
            print(f"  sops {app_dir}/secret.yaml")


if __name__ == "__main__":
    main()
