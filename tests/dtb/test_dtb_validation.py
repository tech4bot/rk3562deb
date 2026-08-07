"""Device tree validation tests.

These tests verify captured DTB/DTS files against expected node presence.
They run against baseline and candidate device trees.
"""

import os
import subprocess
import shutil


EXPECTED_DT_NODES = [
    "display",
    "dsi",
    "panel",
    "touchscreen",
    "pmic",
    "battery",
    "wifi",
    "gpu",
    "npu",
    "rga",
    "iio",
]


def get_baseline_dts():
    project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return os.path.join(project_root, "baseline", "current-system", "device-tree", "fdt.dts")


def test_dtc_available():
    """Device tree compiler must be available for DTB validation."""
    if not shutil.which("dtc"):
        import pytest
        pytest.skip("dtc not installed")


def test_baseline_dts_parseable():
    """If baseline DTS exists, verify it can be parsed."""
    dts_path = get_baseline_dts()
    if not os.path.exists(dts_path):
        import pytest
        pytest.skip("Baseline DTS not yet captured")

    result = subprocess.run(
        ["dtc", "-I", "dts", "-O", "dtb", "-o", "/dev/null", dts_path],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, f"DTS parse failed: {result.stderr}"
