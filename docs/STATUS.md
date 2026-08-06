# Project Status — Samwise / Doogee U10 Armbian Port

**Snapshot date: 2026-08-05.** Evaluated against both trees on Conrad
(`~/repos/rk3562deb` and `~/repos/ArmbianBuild`), not from memory. Previous
full evaluation: the 2026-07-27 TASKS.md reconciliation.

## Headline

The B-1 vendor-kernel retarget (D012/D013) has been fully staged since the
evening of 2026-07-27 and **has never been built**. Nothing has changed on
disk in the nine days since. The single gating action is unchanged:

```bash
cd ~/repos/ArmbianBuild && ./compile.sh kernel BOARD=doogee-u10 BRANCH=vendor
```

## What is done and verified

- **Both repos fully pushed.** ArmbianBuild `main` == `fork/main`
  (GeospatialDaryl/build @ `37cb49b45`, 12 commits ahead of upstream
  armbian/build). rk3562deb `main` == `origin/main` (`f9e6544`). The
  "push local commits" item in TASKS.md predates this and is now closed.
- **Patch set is sound against the vendor tree.** All three patches in
  `userpatches/kernel/rk3562-doogee-u10/` apply cleanly (`git apply --check`)
  to the pristine cached clone of `rockchip-linux/kernel develop-6.1` at
  `b4ef083dc` — re-verified this snapshot, including the RKNPU patch.
- **Build inputs are all in place**: board config with vendor-tree retarget
  hook + D013 hook; Seekwave extension (driver vendoring +
  Kconfig/Makefile line-merge + config symbols + `CONFIG_EXTRA_FIRMWARE`);
  sdboot extension with RKNS/FIT magic gates; boot blobs present in
  `userpatches/misc/doogee-u10/`.
- **Docs current through D013** — DECISIONS.md carries D001–D013;
  KERNEL_PROVENANCE.md written 2026-08-05 (was the Phase-1 stub).

## Clarified this evaluation

- `cache/sources/rockchip-linux-develop-6.1` is a **manual clone**, not an
  Armbian-managed tree (plain clone of rockchip-linux/kernel;
  Armbian's own kernel trees live in `cache/git-bare/kernel` +
  `cache/sources/linux-kernel-worktree/`). It was used for patch
  verification. The modified `rockchip_linux_defconfig` in it is
  **byte-identical to `rk3562deb/overlay/.../rockchip_linux_defconfig`** —
  a reference copy, not unsaved work, and irrelevant to the build both
  because Armbian uses its own config base (D013) and because Armbian
  never reads this directory.
- **`cache/git-bare/kernel` is empty.** The first B-1 build has to fetch
  the whole of rockchip-linux/kernel from scratch — a multi-GB clone before
  any compilation starts. Budget time and disk for it; the existing
  `linux-kernel-worktree/6.1__rk35xx__arm64` is from the retired
  armbian/linux-rockchip era and will not be reused.
- Known-good kernel identity has a **conflicting record** — `#131` (TASKS
  reconciliation) vs `#2` (direct uname capture in
  `~/rk_tablet/notes/samwise-target-facts.txt`); flagged in
  KERNEL_PROVENANCE.md, resolve with one `uname -a` on samwise.

## Blockers and next actions, in order

1. **Kernel-only build** under the retarget (command above). Watch for:
   the two `custom_kernel_config` hooks' alerts appearing in the log (they
   silently no-op on the pass with no `.config`), and diffconfig warnings
   for renamed/dropped symbols. Then check the produced `.config` against
   the ⚠️ rows in KERNEL_PROVENANCE.md — chiefly **GPU driver contention**:
   Armbian's base carries `MALI_BIFROST=y` + `MALI_MIDGARD=y` +
   `DRM_PANFROST=m` together, where the proven defconfig disables panfrost
   and drops Midgard. Secondary: `=m` vs `=y` on GSL3673_800X1280,
   GS_DA228E, GSENSOR_DEVICE, SENSOR_DEVICE. None forced by a hook.
2. **Full image**: `./compile.sh build BOARD=doogee-u10 BRANCH=vendor
   RELEASE=bookworm`. First image where the built DTB (not a swapped blob)
   carries the panel fix.
3. **Fill `~/samwise-preseed.env`** (still placeholder-only, 3 markers) and
   inject the first-boot bypass into the B-1 image — per TASKS Phase 5 the
   old panelfix image is not a valid target (no wifi driver).
4. **First boot + `capture-matrix.sh`** — all 20 matrix rows are still
   unrecorded; evidence dir is empty.
5. Then the remaining Phase 4b ports: RK817 battery/charging, poweroff
   patch, overlay-delta audit; cameras stay deferred.

## Standing risks (unchanged, restated)

- **`userpatches/` is force-tracked against upstream's `.gitignore`** in
  ArmbianBuild — 113 files including the only copy of the boot blobs and
  the vendored Seekwave driver on that side. A `git clean -x` treats them
  as disposable. (Mitigated: all committed and pushed to the fork; the
  driver's source of truth is rk3562deb `overlay/`.)
- Board config is still `doogee-u10.wip` with no maintainer — fine locally,
  blocks any upstreaming.
- HARDWARE_TEST_MATRIX row 14 methodology gap (targets tmpfs `/tmp`),
  flagged 2026-07-12, still uncorrected.
- Stale path in a comment: `doogee-u10-seekwave-wifi.sh` header still says
  the DT patch lives in `userpatches/kernel/rk35xx-vendor-6.1/`; it moved
  to `rk3562-doogee-u10/` in the retarget. Cosmetic.
- `C:\Users\vandy\samwise-armbian-panelfix.img` is obsolete (wrong kernel
  base, no wifi); delete once a B-1 image exists.

## Pointers

- Task tracker: `docs/TASKS.md` (phase-by-phase, reconciled 2026-07-27,
  push item closed 2026-08-05)
- Decisions: `docs/DECISIONS.md` (D001–D013)
- Kernel provenance: `docs/KERNEL_PROVENANCE.md`
- Narrative/risk register: `docs/Samwise_Senior_AI_Architect_Overview.md`
- Build fork: `~/repos/ArmbianBuild` (GeospatialDaryl/build)
