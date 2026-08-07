"""Tests for image manifest structure and required fields."""

import json
import os
import glob


REQUIRED_FIELDS = [
    "project",
    "target",
    "profile",
    "created_at",
    "armbian_build_commit",
    "overlay_revision",
    "rootfs_release",
    "eMMC_write_policy",
    "test_status",
]


def find_manifests():
    project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    pattern = os.path.join(project_root, "manifests", "images", "*.manifest.json")
    return glob.glob(pattern)


def test_manifest_schema():
    """Verify any existing manifests have all required fields."""
    manifests = find_manifests()
    for path in manifests:
        with open(path) as f:
            data = json.load(f)
        for field in REQUIRED_FIELDS:
            assert field in data, f"{os.path.basename(path)} missing field: {field}"
        assert data.get("eMMC_write_policy") == "forbidden", (
            f"{os.path.basename(path)}: eMMC_write_policy must be 'forbidden'"
        )
        assert data.get("project") == "rk3562deb"
        assert data.get("target") == "samwise"


def test_emmc_policy_always_forbidden():
    """Verify no manifest allows eMMC writes."""
    manifests = find_manifests()
    for path in manifests:
        with open(path) as f:
            data = json.load(f)
        assert data.get("eMMC_write_policy") == "forbidden", (
            f"CRITICAL: {path} allows eMMC writes"
        )
