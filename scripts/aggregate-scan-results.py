#!/usr/bin/env python3
"""Aggregate a directory of Trivy JSON scan results into one Markdown report.

Usage: aggregate-scan-results.py <results-dir>

Each file in <results-dir> is expected to be Trivy's --format json output
for a single image (see image-scan-report.yaml). Prints a Markdown table
of every HIGH/CRITICAL fixable finding, grouped by image, to stdout.
"""
import json
import sys
from pathlib import Path

SEVERITY_ORDER = {"CRITICAL": 0, "HIGH": 1}


def load_findings(results_dir):
    findings = []
    for path in sorted(Path(results_dir).glob("*.json")):
        try:
            data = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
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
    return findings


def render(findings):
    if not findings:
        return "No fixable HIGH/CRITICAL vulnerabilities found across any scanned image."

    by_image = {}
    for f in findings:
        by_image.setdefault(f["image"], []).append(f)

    lines = [
        f"Found {len(findings)} fixable HIGH/CRITICAL finding(s) across {len(by_image)} image(s).",
        "",
    ]
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
    if len(sys.argv) != 2:
        print("usage: aggregate-scan-results.py <results-dir>", file=sys.stderr)
        sys.exit(1)
    print(render(load_findings(sys.argv[1])))
