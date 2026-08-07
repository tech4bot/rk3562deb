#!/usr/bin/env python3
"""Compare a known-good baseline against a candidate system report.

Detects and classifies differences as expected, accepted, or regression.
Produces both human-readable and machine-readable output.
"""

import argparse
import json
import os
import sys
from pathlib import Path
from datetime import datetime


def read_file(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace").strip()
    except FileNotFoundError:
        return None


def parse_modules(text):
    if not text:
        return set()
    modules = set()
    for line in text.splitlines():
        parts = line.split()
        if parts and not parts[0].startswith("Module"):
            modules.add(parts[0])
    return modules


def parse_lsblk(text):
    if not text:
        return []
    devices = []
    for line in text.splitlines()[1:]:
        parts = line.split()
        if parts:
            devices.append(parts[0].strip("├─└─│ "))
    return devices


def parse_input_devices(text):
    if not text:
        return {}
    devices = {}
    current_name = None
    for line in text.splitlines():
        if line.startswith("N: Name="):
            current_name = line.split("=", 1)[1].strip('" ')
        elif line.startswith("H: Handlers=") and current_name:
            devices[current_name] = line.split("=", 1)[1].strip()
    return devices


def parse_services(text):
    if not text:
        return set()
    services = set()
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[0].endswith(".service"):
            services.add(parts[0])
    return services


def compare_field(baseline_dir, candidate_dir, filename, field_name):
    b = read_file(os.path.join(baseline_dir, filename))
    c = read_file(os.path.join(candidate_dir, filename))

    result = {
        "field": field_name,
        "file": filename,
        "baseline": b,
        "candidate": c,
    }

    if b is None and c is None:
        result["status"] = "both-missing"
    elif b is None:
        result["status"] = "new-in-candidate"
    elif c is None:
        result["status"] = "missing-in-candidate"
        result["classification"] = "regression"
    elif b == c:
        result["status"] = "identical"
    else:
        result["status"] = "changed"
        result["classification"] = "needs-review"

    return result


def compare_sets(baseline_set, candidate_set, field_name):
    added = candidate_set - baseline_set
    removed = baseline_set - candidate_set
    common = baseline_set & candidate_set

    result = {
        "field": field_name,
        "added": sorted(added),
        "removed": sorted(removed),
        "common_count": len(common),
    }

    if removed:
        result["classification"] = "needs-review"
    elif added:
        result["classification"] = "expected"
    else:
        result["status"] = "identical"

    return result


def main():
    parser = argparse.ArgumentParser(description="Compare samwise baselines")
    parser.add_argument("--baseline", required=True, help="Baseline directory")
    parser.add_argument("--candidate", required=True, help="Candidate directory")
    parser.add_argument("--output", default="comparison-report.json", help="JSON output")
    parser.add_argument("--human", default="comparison-report.txt", help="Human-readable output")
    args = parser.parse_args()

    report = {
        "comparison_date": datetime.now().isoformat(),
        "baseline_dir": args.baseline,
        "candidate_dir": args.candidate,
        "fields": [],
        "sets": [],
    }

    # Simple field comparisons
    field_checks = [
        ("uname.txt", "kernel_release"),
        ("kernel-version.txt", "kernel_version"),
        ("cmdline.txt", "boot_cmdline"),
        ("hostname.txt", "hostname"),
        ("os-release.txt", "os_release"),
        ("device-tree/model.txt", "dt_model"),
        ("device-tree/compatible.txt", "dt_compatible"),
        ("sysfs/battery-status.txt", "battery_status"),
        ("sysfs/battery-capacity.txt", "battery_capacity"),
        ("audio-cards.txt", "audio_cards"),
        ("sysfs/gpu-devices.txt", "gpu_devices"),
        ("sysfs/mpp-service.txt", "mpp_service"),
        ("sysfs/rga-device.txt", "rga_device"),
        ("sysfs/rknn-device.txt", "rknn_device"),
        ("sysfs/drm-connectors.txt", "drm_connectors"),
    ]

    for filename, field_name in field_checks:
        result = compare_field(args.baseline, args.candidate, filename, field_name)
        report["fields"].append(result)

    # Set comparisons
    b_modules = parse_modules(read_file(os.path.join(args.baseline, "modules.txt")))
    c_modules = parse_modules(read_file(os.path.join(args.candidate, "modules.txt")))
    report["sets"].append(compare_sets(b_modules, c_modules, "kernel_modules"))

    b_input = parse_input_devices(read_file(os.path.join(args.baseline, "input-devices.txt")))
    c_input = parse_input_devices(read_file(os.path.join(args.candidate, "input-devices.txt")))
    report["sets"].append(compare_sets(set(b_input.keys()), set(c_input.keys()), "input_devices"))

    b_services = parse_services(read_file(os.path.join(args.baseline, "services-running.txt")))
    c_services = parse_services(read_file(os.path.join(args.candidate, "services-running.txt")))
    report["sets"].append(compare_sets(b_services, c_services, "running_services"))

    # Count regressions
    regressions = []
    needs_review = []
    for field in report["fields"]:
        cls = field.get("classification", "")
        if cls == "regression":
            regressions.append(field["field"])
        elif cls == "needs-review":
            needs_review.append(field["field"])
    for s in report["sets"]:
        cls = s.get("classification", "")
        if cls == "regression":
            regressions.append(s["field"])
        elif cls == "needs-review":
            needs_review.append(s["field"])

    report["summary"] = {
        "regressions": regressions,
        "needs_review": needs_review,
        "regression_count": len(regressions),
        "review_count": len(needs_review),
    }

    # Write JSON
    with open(args.output, "w") as f:
        json.dump(report, f, indent=2, default=str)

    # Write human-readable
    with open(args.human, "w") as f:
        f.write("=== Samwise Baseline Comparison Report ===\n")
        f.write(f"Date: {report['comparison_date']}\n")
        f.write(f"Baseline: {args.baseline}\n")
        f.write(f"Candidate: {args.candidate}\n\n")

        if regressions:
            f.write("!! REGRESSIONS !!\n")
            for r in regressions:
                f.write(f"  - {r}\n")
            f.write("\n")

        if needs_review:
            f.write("NEEDS REVIEW (changed from baseline):\n")
            for r in needs_review:
                f.write(f"  - {r}\n")
            f.write("\n")

        f.write("--- Field Comparisons ---\n")
        for field in report["fields"]:
            status = field.get("status", field.get("classification", "unknown"))
            f.write(f"\n[{status.upper()}] {field['field']} ({field['file']})\n")
            if status == "changed":
                b = field.get("baseline", "")
                c = field.get("candidate", "")
                if b and c and len(b) < 200 and len(c) < 200:
                    f.write(f"  baseline:  {b}\n")
                    f.write(f"  candidate: {c}\n")

        f.write("\n--- Set Comparisons ---\n")
        for s in report["sets"]:
            f.write(f"\n{s['field']}:\n")
            if s.get("status") == "identical":
                f.write(f"  identical ({s['common_count']} items)\n")
            else:
                if s.get("removed"):
                    f.write(f"  REMOVED: {', '.join(s['removed'][:20])}\n")
                if s.get("added"):
                    f.write(f"  ADDED:   {', '.join(s['added'][:20])}\n")
                f.write(f"  common:  {s['common_count']} items\n")

        f.write(f"\n=== Summary: {len(regressions)} regressions, {len(needs_review)} need review ===\n")

    print(f"JSON report: {args.output}")
    print(f"Human report: {args.human}")
    print(f"Regressions: {len(regressions)}, Needs review: {len(needs_review)}")

    if regressions:
        sys.exit(1)
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
