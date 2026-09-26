#!/usr/bin/env python3
"""Extract container image refs from HelmRelease values for CI image scanning.

Walks each given YAML file looking for dicts with a "tag" + sibling
"repository" key (bjw-s app-template's image schema), joining a sibling
"registry" key when present (kube-prometheus-stack/grafana split it out
instead of folding it into "repository"). Prints one deduped
"repository[:tag][@digest]" ref per line, sorted.

Usage: extract-images.py <file>...
"""
import sys
from pathlib import Path

import yaml


def find_images(node, out):
    if isinstance(node, dict):
        tag = node.get("tag")
        repository = node.get("repository")
        if isinstance(tag, str) and isinstance(repository, str):
            registry = node.get("registry")
            repo = f"{registry.rstrip('/')}/{repository}" if isinstance(registry, str) else repository
            if "@sha256:" in tag:
                _, digest = tag.split("@", 1)
                out.add(f"{repo}@{digest}")
            else:
                out.add(f"{repo}:{tag}")
        for value in node.values():
            find_images(value, out)
    elif isinstance(node, list):
        for item in node:
            find_images(item, out)


def extract(paths):
    images = set()
    for path in paths:
        p = Path(path)
        if not p.is_file():
            continue
        try:
            docs = list(yaml.safe_load_all(p.read_text()))
        except yaml.YAMLError:
            continue
        for doc in docs:
            find_images(doc, images)
    return images


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: extract-images.py <file>...", file=sys.stderr)
        sys.exit(1)
    for image in sorted(extract(sys.argv[1:])):
        print(image)
