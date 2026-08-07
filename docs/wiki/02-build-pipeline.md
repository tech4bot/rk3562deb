# 02 — Build Pipeline on Conrad

## Repository map

| Path | Role |
|---|---|
| `~/repos/ArmbianBuild` | Armbian Build Framework checkout (fork; carries the board definition). Direct builds happen here. |
| `~/repos/rk3562deb` | Project overlay repo: docs, decisions, baseline evidence, scripts, and the **canonical** userpatches under `platform/armbian/userpatches/` |
| `~/backups/samwise` | Compressed image backups of the device |

Two build paths exist:

1. **Direct (currently used):** run `compile.sh` inside `~/repos/ArmbianBuild`.
   Userpatches are read from `~/repos/ArmbianBuild/userpatches/`.
2. **Scripted (Layer-4 tooling):** `rk3562deb/scripts/prepare-armbian-worktree.sh`
   copies `platform/armbian/userpatches/` into a disposable worktree, then
   `build-image.sh --profile <samwise-minimal|samwise-hardware-test|samwise-tablet-dev>`
   drives the build. Keep patch content **identical in both locations** —
   currently each NPU patch exists in both.

## Key configuration

- **Board definition:** `config/boards/doogee-u10.wip`
  - `BOOT_FDT_FILE="rockchip/rk3562-rk817-tablet-v10.dtb"`
  - `KERNEL_TARGET="vendor"`, `SRC_EXTLINUX="yes"` (SD boots via extlinux, D007)
  - `SRC_CMDLINE` includes `video=DSI-1:800x1280@60,rotate=90` and the 1500000-baud serial console
- **Kernel family:** `config/sources/families/rk35xx.conf`, `vendor` case:
  - Source: `https://github.com/armbian/linux-rockchip.git`
  - Branch pin: `rk-6.1-rkr3` → kernel **6.1.75**, local branch `kernel-rk35xx-6.1`
- **Kernel config:** `config/kernel/linux-rk35xx-vendor.config` — RKNPU block is
  `CONFIG_ROCKCHIP_RKNPU=y`, `CONFIG_ROCKCHIP_RKNPU_DEBUG_FS=y`,
  `CONFIG_ROCKCHIP_RKNPU_DRM_GEM=y` (identical to the stock device's config)
- **Userpatches:** `userpatches/kernel/rk35xx-vendor-6.1/` — applied
  automatically to the kernel tree for this family/branch on every build

## Build commands

All run from `~/repos/ArmbianBuild`, in an interactive terminal (sudo prompts):

```bash
# Kernel packages only (~3 min incremental): image/dtb/headers debs
./compile.sh kernel BOARD=doogee-u10 BRANCH=vendor

# Full flashable image (kernel + bookworm rootfs + BSP)
./compile.sh build BOARD=doogee-u10 BRANCH=vendor RELEASE=bookworm

# Interactive kernel config editor (writes back to config/kernel/…)
./compile.sh kernel-config BOARD=doogee-u10 BRANCH=vendor
```

`RELEASE=bookworm` is deliberate: it matches the stock system and the spec, and
keeps the RKNN userland environment (glibc) apples-to-apples. See the wiki
index's project summary and D003 for the Track A rationale.

## Where artifacts land

| Artifact | Location |
|---|---|
| Flashable image + `.sha` + manifest `.txt` | `output/images/Armbian-unofficial_<ver>_Doogee-u10_bookworm_vendor_<kver>.img` |
| Kernel/DTB/BSP debs | `output/debs/` (hashed variants in `output/packages-hashed/`) |
| Build logs (ANSI) | `output/logs/log-*.log.ans` — view with `less -RS` |
| Kernel source worktree | `cache/sources/linux-kernel-worktree/6.1__rk35xx__arm64` |
| Bare git cache | `cache/git-bare/kernel` (shared; may not be writable by your user) |

The artifact version string encodes content hashes, e.g.
`6.1.75-S00b3-D558b-P6e1c-…` — the `P` component is the **patch-set hash**, so
it changes whenever a userpatch is added or modified. That is a quick way to
confirm a patch actually entered a build.

## Verifying a built kernel/DTB without flashing

```bash
# Extract the DTB deb and decompile the tablet DTB
dpkg-deb -x output/debs/linux-dtb-vendor-rk35xx_<ver>.deb /tmp/dtbcheck
dtc -I dtb -O dts /tmp/dtbcheck/boot/dtb-*/rockchip/rk3562-rk817-tablet-v10.dtb \
  | awk '/npu@ff300000/,/^\t\};/' | grep -E 'status|supply'
# expect: status = "okay" and an rknpu-supply phandle resolving to vdd_npu

# Confirm a userpatch was applied in a given build
grep -l "enable-rknpu" output/logs/log-kernel-*.log.ans
```

To test-compile a DTS change without any Armbian run (fast iteration):

```bash
K=~/repos/ArmbianBuild/cache/sources/linux-kernel-worktree/6.1__rk35xx__arm64
cpp -nostdinc -I $K/include -I $K/arch/arm64/boot/dts/rockchip \
    -I $K/scripts/dtc/include-prefixes -undef -D__DTS__ \
    -x assembler-with-cpp patched.dts -o pre.dts
dtc -I dts -O dtb -o test.dtb pre.dts   # then decompile and inspect
```

And to check that a patch applies before building:

```bash
cd $K && git apply --check /path/to/your.patch && echo OK
```

## Practical gotchas

- `compile.sh` **requires sudo** when Docker is absent; it fails immediately in
  shells that cannot prompt (`sudo: a terminal is required…`).
- The kernel worktree is shared build state — never edit it directly; changes
  belong in userpatches. Armbian resets and re-applies patches each build.
- The bare git cache only holds the pinned branch; fetching other upstream
  branches into it may fail on permissions. Use a scratch clone with
  `git fetch --depth 1 --filter=blob:none origin <sha>` + sparse-checkout to
  examine upstream commits cheaply.
- `getent hosts samwise` fails on Conrad (WSL2/mDNS) — use the tablet's IP.
