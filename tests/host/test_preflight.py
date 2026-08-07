"""Host-side tests for the build environment."""

import os
import shutil
import subprocess


def test_git_available():
    assert shutil.which("git") is not None


def test_project_on_linux_fs():
    project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    assert not project_root.startswith("/mnt/c"), "Project must be on Linux filesystem"


def test_scripts_are_executable():
    scripts_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "scripts",
    )
    for name in os.listdir(scripts_dir):
        if name.endswith(".sh"):
            path = os.path.join(scripts_dir, name)
            assert os.access(path, os.X_OK), f"{name} is not executable"


def test_profiles_exist():
    profiles_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "platform", "armbian", "profiles",
    )
    expected = ["samwise-minimal.env", "samwise-hardware-test.env", "samwise-tablet-dev.env"]
    for profile in expected:
        assert os.path.exists(os.path.join(profiles_dir, profile)), f"Missing profile: {profile}"


def test_emmc_guard_in_flash_script():
    script = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "scripts", "flash-image-safely.sh",
    )
    with open(script) as f:
        content = f.read()
    assert "mmcblk2" in content, "flash script must guard against eMMC writes"
