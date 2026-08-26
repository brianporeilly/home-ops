#!/usr/bin/env python3
"""Aggregate a directory of Trivy JSON scan results into a Markdown report.

Usage: aggregate-scan-results.py <results-dir> [--full]

Each file in <results-dir> is expected to be Trivy's --format json output
for a single image (see image-scan-report.yaml), one file per scanned
image regardless of whether it had findings. Default output is a
per-image summary table (severity counts only) sized to fit in a PR/issue
comment; --full prints every CVE/package pair instead, for the
downloadable artifact.
"""
import json
import sys
from pathlib import Path

SEVERITY_ORDER = {"CRITICAL": 0, "HIGH": 1}


def load_results(results_dir):
    """Returns (findings, total_images_scanned)."""
    findings = []
    scanned = 0
    for path in sorted(Path(results_dir).glob("*.json")):
        try:
            data = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        scanned += 1
        image = data.get("ArtifactName", path.stem)
        for result in data.get("Results") or []:
            for vuln in result.get("Vulnerabilities") or []:
                severity = vuln.get("Severity", "")
                if severity not in SEVERITY_ORDER:
                    continue
                findings.append(
                    {
                        "image": image,
                        "severity": severity,
                        "id": vuln.get("VulnerabilityID", ""),
                        "pkg": vuln.get("PkgName", ""),
                        "installed": vuln.get("InstalledVersion", ""),
                        "fixed": vuln.get("FixedVersion", ""),
                    }
                )
    return findings, scanned


def group_by_image(findings):
    by_image = {}
    for f in findings:
        by_image.setdefault(f["image"], []).append(f)
    return by_image


def render_summary(findings, scanned):
    by_image = group_by_image(findings)
    if not by_image:
        return f"No fixable HIGH/CRITICAL vulnerabilities found across {scanned} scanned image(s)."

    lines = [
        f"{len(by_image)} of {scanned} scanned image(s) have fixable HIGH/CRITICAL findings "
        f"({len(findings)} total).",
        "",
        "| Image | Critical | High |",
        "|---|---|---|",
    ]
    for image in sorted(by_image, key=lambda i: (-len(by_image[i]), i)):
        vulns = by_image[image]
        critical = sum(1 for f in vulns if f["severity"] == "CRITICAL")
        high = sum(1 for f in vulns if f["severity"] == "HIGH")
        lines.append(f"| `{image}` | {critical} | {high} |")
    return "\n".join(lines)


def render_full(findings, scanned):
    by_image = group_by_image(findings)
    if not by_image:
        return f"No fixable HIGH/CRITICAL vulnerabilities found across {scanned} scanned image(s)."

    lines = [f"{len(by_image)} of {scanned} scanned image(s) have fixable HIGH/CRITICAL findings.", ""]
    for image in sorted(by_image, key=lambda i: (-len(by_image[i]), i)):
        vulns = sorted(by_image[image], key=lambda f: (SEVERITY_ORDER[f["severity"]], f["id"]))
        lines.append(f"### `{image}`")
        lines.append("")
        lines.append("| Severity | CVE | Package | Installed | Fixed |")
        lines.append("|---|---|---|---|---|")
        for f in vulns:
            lines.append(f"| {f['severity']} | {f['id']} | {f['pkg']} | {f['installed']} | {f['fixed']} |")
        lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    args = sys.argv[1:]
    full = "--full" in args
    positional = [a for a in args if a != "--full"]
    if len(positional) != 1:
        print("usage: aggregate-scan-results.py <results-dir> [--full]", file=sys.stderr)
        sys.exit(1)
    all_findings, total_scanned = load_results(positional[0])
    render = render_full if full else render_summary
    print(render(all_findings, total_scanned))
