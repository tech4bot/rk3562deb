#!/bin/bash
set -e

export PATH="/usr/sbin:/sbin:$PATH"

# RK3562 Debian 13 Builder

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC_DIR="${ROOT_DIR}/src"
OUT_DIR="${ROOT_DIR}/out"
OUTPUT_DIR="${ROOT_DIR}/output"

# Versions & URLs
UBOOT_URL="https://github.com/Firefly-rk-linux/u-boot.git"
UBOOT_BRANCH="rk356x/firefly-5.10"
KERNEL_URL="https://github.com/rockchip-linux/kernel.git"
KERNEL_BRANCH="develop-6.1"
RKBIN_URL="https://github.com/rockchip-linux/rkbin.git"
RKBIN_BRANCH="master"

# RK3562 configs
UBOOT_DEFCONFIG="rk3562_defconfig"
KERNEL_DEFCONFIG="rockchip_linux_defconfig"
KERNEL_DTB="rk3562-rk817-tablet-v10.dtb"
KERNEL_DTB_PANFROST="rk3562-rk817-tablet-v10-panfrost.dtb"
RKDEBIAN_DISPLAY_SERVER="${RKDEBIAN_DISPLAY_SERVER:-wayland}"
RKDEBIAN_UI_SESSION="${RKDEBIAN_UI_SESSION:-phosh}"
RKDEBIAN_GPU_STACK="${RKDEBIAN_GPU_STACK:-mali}"
RKDEBIAN_CPU_GOVERNOR="${RKDEBIAN_CPU_GOVERNOR:-performance}"
RKDEBIAN_FORCE_CLEAN_ROOTFS="${RKDEBIAN_FORCE_CLEAN_ROOTFS:-0}"

CROSS_COMPILE="aarch64-linux-gnu-"
CPU_THREADS=$(nproc)
MEM_THREADS=$CPU_THREADS
if [ -r /proc/meminfo ]; then
    mem_total_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
    # Keep kernel compile parallelism memory-safe on low-RAM hosts.
    # Roughly budget ~2 GiB per compile job to avoid random cc1 terminations.
    if [ -n "${mem_total_kb}" ] && [ "${mem_total_kb}" -gt 0 ] 2>/dev/null; then
        MEM_THREADS=$((mem_total_kb / 1024 / 1024 / 2))
        [ "${MEM_THREADS}" -lt 1 ] && MEM_THREADS=1
    fi
fi
if [ "${MEM_THREADS}" -lt "${CPU_THREADS}" ]; then
    DEFAULT_MAKE_THREADS="${MEM_THREADS}"
else
    DEFAULT_MAKE_THREADS="${CPU_THREADS}"
fi
MAKE_THREADS="${RKDEBIAN_MAKE_THREADS:-${DEFAULT_MAKE_THREADS}}"
case "${MAKE_THREADS}" in
    ''|*[!0-9]*) MAKE_THREADS="${DEFAULT_MAKE_THREADS}" ;;
esac
[ "${MAKE_THREADS}" -lt 1 ] && MAKE_THREADS=1

echo "=== RK3562 Debian 13 Builder ==="

usage() {
    cat <<'EOF'
Usage: ./build.sh [options] {check|lunch|uboot|extboot|updateimg|updatepkg|compile|rootfs|image|all}

Options:
  --ui-session {phosh}
  --gpu-stack {mali|panfrost}
  --display-server {auto|wayland|x11}
  --cpu-governor VALUE
  --force-clean-rootfs
  --no-force-clean-rootfs
  -h, --help
EOF
}

parse_args() {
    local argv=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --ui-session)
                [ "$#" -ge 2 ] || { echo "[-] Error: --ui-session requires a value."; exit 1; }
                RKDEBIAN_UI_SESSION="$2"
                shift 2
                ;;
            --ui-session=*)
                RKDEBIAN_UI_SESSION="${1#*=}"
                shift
                ;;
            --gpu-stack)
                [ "$#" -ge 2 ] || { echo "[-] Error: --gpu-stack requires a value."; exit 1; }
                RKDEBIAN_GPU_STACK="$2"
                shift 2
                ;;
            --gpu-stack=*)
                RKDEBIAN_GPU_STACK="${1#*=}"
                shift
                ;;
            --display-server)
                [ "$#" -ge 2 ] || { echo "[-] Error: --display-server requires a value."; exit 1; }
                RKDEBIAN_DISPLAY_SERVER="$2"
                shift 2
                ;;
            --display-server=*)
                RKDEBIAN_DISPLAY_SERVER="${1#*=}"
                shift
                ;;
            --cpu-governor)
                [ "$#" -ge 2 ] || { echo "[-] Error: --cpu-governor requires a value."; exit 1; }
                RKDEBIAN_CPU_GOVERNOR="$2"
                shift 2
                ;;
            --cpu-governor=*)
                RKDEBIAN_CPU_GOVERNOR="${1#*=}"
                shift
                ;;
            --force-clean-rootfs)
                RKDEBIAN_FORCE_CLEAN_ROOTFS=1
                shift
                ;;
            --no-force-clean-rootfs)
                RKDEBIAN_FORCE_CLEAN_ROOTFS=0
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                while [ "$#" -gt 0 ]; do
                    argv+=("$1")
                    shift
                done
                ;;
            -*)
                echo "[-] Error: unknown option: $1"
                usage
                exit 1
                ;;
            *)
                argv+=("$1")
                shift
                ;;
        esac
    done

    set -- "${argv[@]}"
    CMD="${1:-all}"
}

parse_args "$@"

export RKDEBIAN_DISPLAY_SERVER
export RKDEBIAN_UI_SESSION
export RKDEBIAN_GPU_STACK
export RKDEBIAN_CPU_GOVERNOR
export RKDEBIAN_FORCE_CLEAN_ROOTFS

echo "[*] Build profile: session=${RKDEBIAN_UI_SESSION} gpu=${RKDEBIAN_GPU_STACK} display=${RKDEBIAN_DISPLAY_SERVER} clean_rootfs=${RKDEBIAN_FORCE_CLEAN_ROOTFS}"

case "${RKDEBIAN_DISPLAY_SERVER}" in
    auto|wayland|x11) ;;
    *)
        echo "[-] Error: unsupported RKDEBIAN_DISPLAY_SERVER=${RKDEBIAN_DISPLAY_SERVER} (expected auto, wayland, or x11)."
        exit 1
        ;;
esac

case "${RKDEBIAN_UI_SESSION}" in
    phosh) ;;
    *)
        echo "[-] Error: unsupported RKDEBIAN_UI_SESSION=${RKDEBIAN_UI_SESSION} (expected phosh)."
        exit 1
        ;;
esac

case "${RKDEBIAN_GPU_STACK}" in
    mali|panfrost) ;;
    *)
        echo "[-] Error: unsupported RKDEBIAN_GPU_STACK=${RKDEBIAN_GPU_STACK} (expected mali or panfrost)."
        exit 1
        ;;
esac

verify_rootfs_profile() {
    local profile_file="${OUT_DIR}/rootfs/etc/rkdebian-build-profile"
    local usr_owner
    local pkexec_owner pkexec_mode
    local polkit_helper_owner polkit_helper_mode
    if [ ! -f "${profile_file}" ]; then
        echo "[-] Error: missing ${profile_file}; refusing to package an unverified rootfs."
        exit 1
    fi

    if ! grep -qx "RKDEBIAN_UI_SESSION=${RKDEBIAN_UI_SESSION}" "${profile_file}"; then
        echo "[-] Error: rootfs session profile does not match requested value (${RKDEBIAN_UI_SESSION})."
        cat "${profile_file}"
        exit 1
    fi

    if ! grep -qx "RKDEBIAN_GPU_STACK=${RKDEBIAN_GPU_STACK}" "${profile_file}"; then
        echo "[-] Error: rootfs GPU profile does not match requested value (${RKDEBIAN_GPU_STACK})."
        cat "${profile_file}"
        exit 1
    fi

    if [ ! -f "${OUT_DIR}/rootfs/usr/share/wayland-sessions/phosh.desktop" ]; then
        echo "[-] Error: phosh.desktop is missing from the rootfs."
        exit 1
    fi

    # Guard against packaging a rootfs tree with corrupted ownership/permissions.
    # This catches cases where recursive chown operations accidentally touched
    # system paths like /usr in a reused out/rootfs tree.
    usr_owner=$(stat -c '%u:%g' "${OUT_DIR}/rootfs/usr" 2>/dev/null || echo "")
    if [ "${usr_owner}" != "0:0" ]; then
        echo "[-] Error: ${OUT_DIR}/rootfs/usr is owned by ${usr_owner} (expected 0:0)."
        echo "    Rootfs ownership appears corrupted."
        echo "    Rebuild with: RKDEBIAN_FORCE_CLEAN_ROOTFS=1 ./build.sh rootfs"
        exit 1
    fi

    if [ ! -e "${OUT_DIR}/rootfs/usr/bin/pkexec" ]; then
        echo "[-] Error: missing ${OUT_DIR}/rootfs/usr/bin/pkexec."
        exit 1
    fi
    pkexec_owner=$(stat -c '%u:%g' "${OUT_DIR}/rootfs/usr/bin/pkexec" 2>/dev/null || echo "")
    pkexec_mode=$(stat -c '%a' "${OUT_DIR}/rootfs/usr/bin/pkexec" 2>/dev/null || echo "")
    if [ "${pkexec_owner}" != "0:0" ] || [ "${pkexec_mode}" != "4755" ]; then
        echo "[-] Error: ${OUT_DIR}/rootfs/usr/bin/pkexec is ${pkexec_owner} mode ${pkexec_mode}; expected 0:0 mode 4755."
        echo "    Rootfs ownership/permissions appear corrupted."
        echo "    Rebuild with: RKDEBIAN_FORCE_CLEAN_ROOTFS=1 ./build.sh rootfs"
        exit 1
    fi

    if [ ! -e "${OUT_DIR}/rootfs/usr/lib/polkit-1/polkit-agent-helper-1" ]; then
        echo "[-] Error: missing ${OUT_DIR}/rootfs/usr/lib/polkit-1/polkit-agent-helper-1."
        exit 1
    fi
    polkit_helper_owner=$(stat -c '%u:%g' "${OUT_DIR}/rootfs/usr/lib/polkit-1/polkit-agent-helper-1" 2>/dev/null || echo "")
    polkit_helper_mode=$(stat -c '%a' "${OUT_DIR}/rootfs/usr/lib/polkit-1/polkit-agent-helper-1" 2>/dev/null || echo "")
    if [ "${polkit_helper_owner}" != "0:0" ] || [ "${polkit_helper_mode}" != "4755" ]; then
        echo "[-] Error: ${OUT_DIR}/rootfs/usr/lib/polkit-1/polkit-agent-helper-1 is ${polkit_helper_owner} mode ${polkit_helper_mode}; expected 0:0 mode 4755."
        echo "    Rootfs ownership/permissions appear corrupted."
        echo "    Rebuild with: RKDEBIAN_FORCE_CLEAN_ROOTFS=1 ./build.sh rootfs"
        exit 1
    fi
}

ensure_sdk_compat_layout() {
    mkdir -p "${ROOT_DIR}/app" "${ROOT_DIR}/buildroot" "${ROOT_DIR}/device" \
             "${ROOT_DIR}/docs" "${ROOT_DIR}/external" "${ROOT_DIR}/prebuilts" \
             "${ROOT_DIR}/tools" "${ROOT_DIR}/prebuilt_rootfs" "${OUTPUT_DIR}/update"

    if [ -d "${SRC_DIR}/kernel" ] && [ ! -e "${ROOT_DIR}/kernel" ]; then
        ln -s "src/kernel" "${ROOT_DIR}/kernel"
    fi
    if [ -d "${SRC_DIR}/u-boot" ] && [ ! -e "${ROOT_DIR}/u-boot" ]; then
        ln -s "src/u-boot" "${ROOT_DIR}/u-boot"
    fi
    if [ -d "${SRC_DIR}/rkbin" ] && [ ! -e "${ROOT_DIR}/rkbin" ]; then
        ln -s "src/rkbin" "${ROOT_DIR}/rkbin"
    fi
}

select_lunch() {
    cat << 'EOF'
############### Rockchip Linux SDK (compat) ###############

Pick a defconfig:
1. firefly_rk3562_aio-3562jq_debian_defconfig

Which would you like? [1]:
EOF
    read -r choice
    choice=${choice:-1}
    case "${choice}" in
        1)
            echo "firefly_rk3562_aio-3562jq_debian_defconfig" > "${ROOT_DIR}/.rk_lunch"
            echo "[+] Selected firefly_rk3562_aio-3562jq_debian_defconfig"
            ;;
        *)
            echo "[!] Unsupported selection '${choice}', defaulting to firefly_rk3562_aio-3562jq_debian_defconfig"
            echo "firefly_rk3562_aio-3562jq_debian_defconfig" > "${ROOT_DIR}/.rk_lunch"
            ;;
    esac
}

check_deps() {
    echo "[*] Checking dependencies..."
    local deps=("git" "make" "aarch64-linux-gnu-gcc" "bc" "bison" "flex" "dtc" "genimage" "wget" "tar" "mcopy" "debootstrap" "qemu-aarch64-static" "mkfs.ext4" "e2fsck" "xz")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "[-] Error: Missing dependency: $dep. Please install it."
            exit 1
        fi
    done
    echo "[+] All dependencies met."
}

setup_dirs() {
    mkdir -p "${SRC_DIR}"
    mkdir -p "${OUT_DIR}/boot"
    mkdir -p "${OUT_DIR}/rootfs"
    mkdir -p "${OUTPUT_DIR}/update"
    cleanup_stale_rootfs_mounts

    if [ "${EUID}" -ne 0 ]; then
        local repair_outputs=0
        local foreign_output=""

        if [ ! -w "${OUT_DIR}" ] || [ ! -w "${OUT_DIR}/boot" ] || [ ! -w "${OUTPUT_DIR}" ]; then
            repair_outputs=1
        else
            foreign_output=$(find "${OUT_DIR}" "${OUTPUT_DIR}" -xdev -mindepth 1 \
                \( -path "${OUT_DIR}/rootfs" -o -path "${OUT_DIR}/rootfs/*" \) -prune -o \
                \( ! -uid "$(id -u)" -o ! -gid "$(id -g)" \) -print -quit 2>/dev/null || true)
            [ -n "${foreign_output}" ] && repair_outputs=1
        fi

        if [ "${repair_outputs}" -eq 1 ]; then
            echo "[*] Fixing ownership of output directories (excluding rootfs tree)..."
            if ! sudo find "${OUT_DIR}" "${OUTPUT_DIR}" -xdev \
                \( -path "${OUT_DIR}/rootfs" -o -path "${OUT_DIR}/rootfs/*" \) -prune -o \
                -exec chown -h "$(id -u):$(id -g)" {} +; then
                echo "[-] Error: output directories are not writable and ownership fix failed."
                echo "    Please run: sudo chown -R $(id -u):$(id -g) ${OUT_DIR} ${OUTPUT_DIR}"
                exit 1
            fi
        fi
    fi
}

cleanup_stale_rootfs_mounts() {
    local mount_path
    local cleaned=0

    while IFS= read -r mount_path; do
        [ -n "${mount_path}" ] || continue

        if [ "${cleaned}" -eq 0 ]; then
            echo "[*] Releasing stale rootfs bind mounts..."
            cleaned=1
        fi

        if [ "${EUID}" -eq 0 ]; then
            umount -l "${mount_path}" 2>/dev/null || true
        else
            sudo umount -l "${mount_path}" 2>/dev/null || true
        fi
    done < <(
        findmnt -rn -o TARGET 2>/dev/null \
            | awk -v root="${OUT_DIR}/rootfs" '
                $0 == root || index($0, root "/") == 1 {
                    print length($0) "\t" $0
                }
            ' \
            | sort -rn \
            | cut -f2-
    )
}

sanitize_kbuild_cmd_files() {
    local kernel_tree="${1:-.}"
    local bad_cmd_files=()

    while IFS= read -r file; do
        bad_cmd_files+=("${file}")
    done < <(
        find "${kernel_tree}" -type f -name '.*.cmd' -print0 2>/dev/null \
            | xargs -0 -r awk '/\$\(wildcard[^)]*$/ { print FILENAME; nextfile }' 2>/dev/null \
            | sort -u
    )

    if [ "${#bad_cmd_files[@]}" -gt 0 ]; then
        echo "[!] Found ${#bad_cmd_files[@]} malformed kbuild .cmd file(s); removing stale metadata..."
        rm -f "${bad_cmd_files[@]}"
    fi
}

run_build_rootfs() {
    local preserve_env="RKDEBIAN_FORCE_CLEAN_ROOTFS,ROOTFS_IMAGE_SIZE,ROOTFS_HEADROOM_MB,ROOTFS_MIN_MB,RKDEBIAN_DISPLAY_SERVER,RKDEBIAN_GPU_STACK,RKDEBIAN_UI_SESSION,RKDEBIAN_CPU_GOVERNOR,RKDEBIAN_PREINSTALL_FREETUBE,RKDEBIAN_MINIMIZE_IMAGE"
    if [ "${EUID}" -eq 0 ]; then
        bash "${ROOT_DIR}/build_rootfs.sh"
    else
        sudo --preserve-env="${preserve_env}" bash "${ROOT_DIR}/build_rootfs.sh"
    fi
}

apply_local_uboot_patches() {
    local patch_file="${ROOT_DIR}/patches/0001-u-boot-make.sh-only-require-python2-for-legacy-generators.patch"

    if [ ! -f "${patch_file}" ]; then
        return 0
    fi

    echo "[*] Checking local U-Boot patch: $(basename "${patch_file}")"
    if git apply --check "${patch_file}" >/dev/null 2>&1; then
        git apply "${patch_file}"
        echo "[+] Applied local U-Boot patch."
    elif git apply -R --check "${patch_file}" >/dev/null 2>&1; then
        echo "[*] Local U-Boot patch already applied."
    else
        echo "[-] Error: unable to apply local U-Boot patch."
        echo "    Patch: ${patch_file}"
        echo "    Hint: ensure u-boot/make.sh matches expected base or apply manually."
        exit 1
    fi
}

build_uboot() {
    echo "[*] Building U-Boot..."
    cd "${SRC_DIR}"
    
    if [ ! -d "rkbin" ]; then
        git clone --depth 1 -b ${RKBIN_BRANCH} ${RKBIN_URL} rkbin
    fi
    
    if [ ! -d "u-boot" ]; then
        git clone --depth 1 -b ${UBOOT_BRANCH} ${UBOOT_URL} u-boot
    fi
    
    cd u-boot

    if [ "${EUID}" -ne 0 ]; then
        local foreign_owner=""
        foreign_owner=$(find . -maxdepth 3 \( ! -uid "$(id -u)" -o ! -gid "$(id -g)" \) -print -quit 2>/dev/null || true)
        if [ -n "${foreign_owner}" ]; then
            echo "[*] Repairing U-Boot tree ownership..."
            sudo chown -R "$(id -u):$(id -g)" .
        fi
    fi

    apply_local_uboot_patches
    
    export KCFLAGS="-Wno-error"
    ABS_CROSS_COMPILE=$(dirname $(command -v aarch64-linux-gnu-gcc))"/aarch64-linux-gnu-"
    ./make.sh rk3562 CROSS_COMPILE=${ABS_CROSS_COMPILE}
    
    # Store artifacts
    local spl_loader
    spl_loader=$(ls -1 rk3562_spl_loader_*.bin 2>/dev/null | head -n1 || true)
    if [ -z "${spl_loader}" ]; then
        echo "[-] Error: rk3562_spl_loader_*.bin not found in U-Boot output."
        exit 1
    fi

    cp "${spl_loader}" "${OUT_DIR}/idbloader.img"
    cp uboot.img "${OUT_DIR}/u-boot.itb"
    
    echo "[+] U-Boot build complete."
    ensure_sdk_compat_layout
}

build_kernel() {
    echo "[*] Building Linux Kernel..."
    cd "${SRC_DIR}"
    
    if [ ! -d "kernel" ]; then
        git clone --depth 1 -b ${KERNEL_BRANCH} ${KERNEL_URL} kernel
    fi

    cd kernel

    if [ "${EUID}" -ne 0 ]; then
        local foreign_owner=""
        foreign_owner=$(find . -maxdepth 4 \( ! -uid "$(id -u)" -o ! -gid "$(id -g)" \) -print -quit 2>/dev/null || true)
        if [ -n "${foreign_owner}" ]; then
            echo "[*] Repairing kernel tree ownership..."
            sudo chown -R "$(id -u):$(id -g)" .
        fi
    fi

    echo "[*] Kernel parallel jobs: ${MAKE_THREADS} (cpu=${CPU_THREADS}, mem-cap=${MEM_THREADS})"
    sanitize_kbuild_cmd_files "."

    # Apply local overlay (custom drivers, defconfig, DTS, firmware) if existing
    if [ -d "${ROOT_DIR}/overlay" ]; then
        cp -r "${ROOT_DIR}/overlay/." .

        if [ "${RKDEBIAN_GPU_STACK}" = "panfrost" ]; then
            local panfrost_dts="arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dts"
            local rockchip_dts_makefile="arch/arm64/boot/dts/rockchip/Makefile"
            if [ -f "${panfrost_dts}" ] && [ -f "${rockchip_dts_makefile}" ]; then
                if ! grep -q "rk3562-rk817-tablet-v10-panfrost.dtb" "${rockchip_dts_makefile}"; then
                    echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3562-rk817-tablet-v10-panfrost.dtb' >> "${rockchip_dts_makefile}"
                    echo "[*] Added panfrost DTB target to Rockchip Makefile."
                fi
            else
                echo "[!] Warning: panfrost DTS or rockchip Makefile missing; panfrost DTB target may be unavailable."
            fi
        fi

        if [ -d .git ]; then
            local pmic_overlay_files=(
                "drivers/mfd/rk808.c"
                "drivers/power/supply/rk817_battery.c"
                "drivers/power/supply/rk817_charger.c"
            )

            if [ "${RKDEBIAN_KEEP_OVERLAY_PMIC_PATCHES:-0}" = "1" ]; then
                echo "[!] Keeping overlay PMIC kernel files (RKDEBIAN_KEEP_OVERLAY_PMIC_PATCHES=1)."
            else
                # Kernel 6.1 baseline: prefer upstream PMIC drivers first.
                # Set RKDEBIAN_KEEP_OVERLAY_PMIC_PATCHES=1 to re-enable overlay versions.
                for file in "${pmic_overlay_files[@]}"; do
                    if [ -f "${ROOT_DIR}/overlay/${file}" ]; then
                        echo "[*] Restoring upstream kernel file for ${file}."
                        git checkout -- "${file}"
                    fi
                done
            fi
        fi
    fi

    # RK817 hard power-off fix:
    # force DEV_OFF over SMBus in rk817_shutdown_prepare() to avoid
    # poweroff->immediate-reboot behavior on this tablet.
    local rk817_dev_off_patch="${ROOT_DIR}/overlay/kernel-patches/rk817-dev-off-poweroff.patch"
    if [ -f "${rk817_dev_off_patch}" ]; then
        if grep -q "shutdown: SYS_CFG3=0x%02x, wrote DEV_OFF" drivers/mfd/rk808.c; then
            echo "[*] RK817 DEV_OFF shutdown fix already present."
        else
            echo "[*] Applying RK817 DEV_OFF shutdown fix..."
            if ! git apply --whitespace=nowarn "${rk817_dev_off_patch}"; then
                echo "[-] Error: failed to apply RK817 DEV_OFF shutdown fix."
                exit 1
            fi
        fi
    fi

    # RK817 boot SOC OCV calibration fix:
    # always recalibrate dsoc/cap from PMIC OCV register at boot so the
    # battery percentage reflects real pack voltage, not stale scratch state.
    local rk817_boot_ocv_patch="${ROOT_DIR}/overlay/kernel-patches/rk817-boot-ocv-calibration.patch"
    if [ -f "${rk817_boot_ocv_patch}" ]; then
        if grep -q "boot OCV calib" drivers/power/supply/rk817_battery.c; then
            echo "[*] RK817 boot OCV calibration fix already present."
        else
            echo "[*] Applying RK817 boot OCV calibration fix..."
            if ! git apply --whitespace=nowarn "${rk817_boot_ocv_patch}"; then
                echo "[-] Error: failed to apply RK817 boot OCV calibration fix."
                exit 1
            fi
        fi
    fi

    # Use the configured defconfig, with a rockchip fallback if needed.
    if [ ! -f "arch/arm64/configs/${KERNEL_DEFCONFIG}" ]; then
        echo "Warning: ${KERNEL_DEFCONFIG} not found. Attempting rockchip_linux_defconfig..."
        KERNEL_DEFCONFIG="rockchip_linux_defconfig"
    fi

    RKDEBIAN_ALLOW_WARNINGS=1 make ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE} WERROR=0 ${KERNEL_DEFCONFIG}

    # GCC 14 + modern binutils can fail at vmlinux link when patchable-function-entry
    # sections are emitted via dynamic ftrace. Disable those tracing options explicitly.
    if [ -x "scripts/config" ]; then
        scripts/config --disable DYNAMIC_FTRACE_WITH_REGS || true
        scripts/config --disable DYNAMIC_FTRACE || true
        scripts/config --disable FTRACE_MCOUNT_RECORD || true
        scripts/config --disable FTRACE_MCOUNT_USE_PATCHABLE_FUNCTION_ENTRY || true

        # Force Seekwave SWT6621S/EA6621 stack and disable legacy Broadcom path.
        scripts/config --disable BCMDHD || true
        scripts/config --disable AP6XXX || true
        scripts/config --disable WL_ROCKCHIP || true
        scripts/config --disable WIFI_BUILD_MODULE || true
        scripts/config --enable SEEKWAVE_BSP_DRIVERS || true
        scripts/config --enable SKW_SDIOHAL || true
        scripts/config --enable SKW_BSP_UCOM || true
        scripts/config --enable SKW_BSP_BOOT || true
        scripts/config --enable WLAN_VENDOR_SEEKWAVE || true
        scripts/config --enable SKW_VENDOR || true
        scripts/config --enable SKW_DFS_MASTER || true
        scripts/config --module SKW_BT || true
        # Enable Rockchip sensor framework before selecting accel drivers.
        scripts/config --enable SENSOR_DEVICE || true
        scripts/config --enable GSENSOR_DEVICE || true
        scripts/config --enable SKW_LOG_WARN || true
        scripts/config --disable SKW_LOG_DEBUG || true
        scripts/config --disable SKW_LOG_DETAIL || true
        # Build Android-matching accelerometer drivers (SC7A20/DA223).
        scripts/config --enable GS_SC7A20 || true
        scripts/config --enable GS_DA223 || true
        scripts/config --enable GS_DA228E || true
        # Keep Rockchip ASoC options aligned with known-good newrk3562 audio.
        scripts/config --enable SND_CTL_FAST_LOOKUP || true
        scripts/config --enable SND_SOC_ROCKCHIP_ASRC || true
        scripts/config --enable SND_SOC_ROCKCHIP_DLP || true
        scripts/config --enable SND_SOC_ROCKCHIP_DLP_PCM || true
        scripts/config --enable SND_SOC_ROCKCHIP_MULTI_DAIS || true
        scripts/config --enable SND_SOC_ROCKCHIP_PDM_V2 || true
        scripts/config --enable SND_SOC_ROCKCHIP_TRCM || true
        # Avoid black screen before userspace by enabling early fb console/logo.
        scripts/config --enable FRAMEBUFFER_CONSOLE || true
        scripts/config --enable LOGO || true
        scripts/config --enable LOGO_LINUX_CLUT224 || true

        if [ "${RKDEBIAN_GPU_STACK}" = "panfrost" ]; then
            echo "[*] Applying panfrost kernel config overrides..."
            scripts/config --enable DRM_PANFROST || true
            scripts/config --disable MALI_BIFROST || true
            scripts/config --disable MALI_REAL_HW || true
            scripts/config --disable MALI_BIFROST_DEVFREQ || true
            scripts/config --disable MALI_BIFROST_GATOR_SUPPORT || true
        else
            echo "[*] Applying mali kernel config overrides..."
            scripts/config --disable DRM_PANFROST || true
            scripts/config --enable MALI_BIFROST || true
            scripts/config --set-str MALI_PLATFORM_NAME "rk" || true
            scripts/config --enable MALI_REAL_HW || true
            scripts/config --enable MALI_BIFROST_DEVFREQ || true
            scripts/config --enable MALI_BIFROST_GATOR_SUPPORT || true
        fi

        # Vendor Bifrost makefiles force -Werror; newer host toolchains can
        # emit benign warnings that abort the whole build at drivers/gpu.
        if [ "${RKDEBIAN_ALLOW_WARNINGS:-1}" = "1" ] && [ -f "drivers/gpu/arm/bifrost/Makefile" ]; then
            if grep -q "CFLAGS_MODULE += -Wall -Werror" drivers/gpu/arm/bifrost/Makefile; then
                sed -i 's/CFLAGS_MODULE += -Wall -Werror/CFLAGS_MODULE += -Wall/' drivers/gpu/arm/bifrost/Makefile
                echo "[*] Relaxed Mali Bifrost warning policy (-Werror removed) for host-toolchain compatibility."
            fi
        fi

        scripts/config --set-str EXTRA_FIRMWARE "RAM_RW_KERNEL_DRAM.bin ROM_EXEC_KERNEL_IRAM.bin EA6621Q_SEEKWAVE_R00005.bin" || true
        scripts/config --set-str EXTRA_FIRMWARE_DIR "firmware" || true

        RKDEBIAN_ALLOW_WARNINGS=1 make ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE} olddefconfig
    fi

    RKDEBIAN_ALLOW_WARNINGS=1 make ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE} WERROR=0 -j${MAKE_THREADS} Image dtbs modules

    # Find the compiled DTBs (primary + fallback)
    local primary_dtb_name="${KERNEL_DTB}"
    local fallback_dtb_name="${KERNEL_DTB_PANFROST}"
    if [ "${RKDEBIAN_GPU_STACK}" = "panfrost" ]; then
        primary_dtb_name="${KERNEL_DTB_PANFROST}"
        fallback_dtb_name="${KERNEL_DTB}"
    fi

    local dtb_path=""
    local fallback_dtb_path=""
    dtb_path=$(find arch/arm64/boot/dts/rockchip/ -name "${primary_dtb_name}" | head -n1 || true)
    if [ -z "${dtb_path}" ]; then
        dtb_path=$(find arch/arm64/boot/dts/rockchip/ -name "${KERNEL_DTB}" | head -n1 || true)
    fi
    if [ -z "${dtb_path}" ]; then
        dtb_path=$(find arch/arm64/boot/dts/rockchip/ -name "rk3562-*.dtb" | grep -E 'linux|firefly|aio|evb' | head -n1 || true)
    fi
    if [ -z "${dtb_path}" ]; then
        dtb_path=$(find arch/arm64/boot/dts/rockchip/ -name "rk3562-*.dtb" | head -n1 || true)
    fi

    if [ -z "${dtb_path}" ]; then
        echo "[-] Error: Failed to find any rk3562 DTB in arch/arm64/boot/dts/rockchip/."
        exit 1
    fi

    fallback_dtb_path=$(find arch/arm64/boot/dts/rockchip/ -name "${fallback_dtb_name}" | head -n1 || true)
    if [ -z "${fallback_dtb_path}" ]; then
        echo "[!] Warning: fallback DTB (${fallback_dtb_name}) not found; reusing primary DTB as fallback."
        fallback_dtb_path="${dtb_path}"
    fi

    cp "${dtb_path}" "${OUT_DIR}/boot/rk3562.dtb"
    cp "${fallback_dtb_path}" "${OUT_DIR}/boot/rk3562-fallback.dtb"
    cp arch/arm64/boot/Image "${OUT_DIR}/boot/Image"
    
    echo "[+] Using primary DTB: $(basename "${dtb_path}")"
    echo "[+] Using fallback DTB: $(basename "${fallback_dtb_path}")"

    # Install modules for Debian rootfs
    echo "[*] Installing kernel modules..."
    rm -rf "${OUT_DIR}/modules_staging"
    mkdir -p "${OUT_DIR}/modules_staging"
    RKDEBIAN_ALLOW_WARNINGS=1 make ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE} modules_install \
        WERROR=0 \
        INSTALL_MOD_PATH="${OUT_DIR}/modules_staging"
    
    echo "[+] Kernel build complete."
    ensure_sdk_compat_layout
}

create_image() {
    echo "[*] Generating final SD card image..."
    cd "${ROOT_DIR}"
    
    # Setup extlinux.conf into boot folder
    mkdir -p "${OUT_DIR}/boot/extlinux"
    cp "${ROOT_DIR}/extlinux.conf" "${OUT_DIR}/boot/extlinux/extlinux.conf"

    for required in "${OUT_DIR}/idbloader.img" "${OUT_DIR}/u-boot.itb" "${OUT_DIR}/boot/Image" "${OUT_DIR}/boot/rk3562.dtb" "${OUT_DIR}/boot/rk3562-fallback.dtb"; do
        if [ ! -f "${required}" ]; then
            echo "[-] Error: Missing build artifact: ${required}"
            exit 1
        fi
    done
    
    # Cleanup old artifacts
    rm -rf "${OUT_DIR}/tmp"
    mkdir -p "${OUT_DIR}/tmp"

    echo "[*] Creating rootfs.ext4 image..."
    rm -f "${OUT_DIR}/rootfs.ext4"

    # Size policy:
    # - default: auto (rootfs apparent size + headroom, aligned)
    #   * headroom: ROOTFS_HEADROOM_MB (default 512)
    #   * floor:    ROOTFS_MIN_MB      (default 2560)
    # - override: ROOTFS_IMAGE_SIZE=<size> (examples: 4G, 3584M)
    # The rootfs is expanded on first boot by expand-rootfs.service, so we keep
    # the build artifact compact while preserving enough installation headroom.
    local rootfs_image_size="${ROOTFS_IMAGE_SIZE:-auto}"
    if [ "${rootfs_image_size}" = "auto" ]; then
        local rootfs_used_bytes reserve_bytes min_bytes align_bytes size_bytes
        local reserve_mb min_mb
        reserve_mb="${ROOTFS_HEADROOM_MB:-512}"
        min_mb="${ROOTFS_MIN_MB:-2560}"
        case "${reserve_mb}" in
            ''|*[!0-9]*) reserve_mb=512 ;;
        esac
        case "${min_mb}" in
            ''|*[!0-9]*) min_mb=2560 ;;
        esac
        rootfs_used_bytes=$(sudo du -s -B1 "${OUT_DIR}/rootfs" | awk '{print $1}')
        reserve_bytes=$((reserve_mb * 1024 * 1024))
        min_bytes=$((min_mb * 1024 * 1024))
        align_bytes=$((64 * 1024 * 1024))       # align to 64 MiB
        size_bytes=$((rootfs_used_bytes + reserve_bytes))
        if [ "${size_bytes}" -lt "${min_bytes}" ]; then
            size_bytes="${min_bytes}"
        fi
        size_bytes=$(( ( (size_bytes + align_bytes - 1) / align_bytes ) * align_bytes ))
        echo "[*] rootfs usage: $((rootfs_used_bytes / 1024 / 1024)) MiB; headroom: ${reserve_mb} MiB; image size: $((size_bytes / 1024 / 1024)) MiB"
        truncate -s "${size_bytes}" "${OUT_DIR}/rootfs.ext4"
    else
        echo "[*] Using ROOTFS_IMAGE_SIZE=${rootfs_image_size}"
        truncate -s "${rootfs_image_size}" "${OUT_DIR}/rootfs.ext4"
    fi

    # NetworkManager refuses non-root-owned device plugins; fix ownership in
    # source rootfs before packing the final image.
    sudo find "${OUT_DIR}/rootfs/usr/lib" -type f -path '*/NetworkManager/*/libnm-*.so' \
        -exec chown root:root {} + 2>/dev/null || true

    sudo mkfs.ext4 -F \
        -L rootfs \
        -U c0ffee11-2233-4455-6677-8899aabbccdd \
        -d "${OUT_DIR}/rootfs" \
        -E lazy_itable_init=0,lazy_journal_init=0 \
        -O ^metadata_csum_seed,^orphan_file \
        "${OUT_DIR}/rootfs.ext4"

    # Keep a bit more usable free space on small images.
    sudo tune2fs -m 1 "${OUT_DIR}/rootfs.ext4" >/dev/null 2>&1 || true

    if ! sudo e2fsck -pf "${OUT_DIR}/rootfs.ext4"; then
        echo "[-] Error: rootfs.ext4 consistency check failed."
        exit 1
    fi
    
    # genimage requires --rootpath; use an empty dir so it doesn't recreate
    # rootfs.ext4 (which is already pre-built above with mkfs.ext4).
    # Keep it outside --tmppath because genimage requires tmppath to be empty.
    local empty_rootpath="${OUT_DIR}/empty_rootpath"
    rm -rf "${empty_rootpath}"
    mkdir -p "${empty_rootpath}"
    sudo genimage \
        --config "${ROOT_DIR}/genimage.cfg" \
        --rootpath "${empty_rootpath}" \
        --tmppath "${OUT_DIR}/tmp" \
        --inputpath "${OUT_DIR}" \
        --outputpath "${OUT_DIR}"

    cp -f "${OUT_DIR}/rk3562-debian.img" "${OUTPUT_DIR}/update/update.img"
    echo "[*] Compressing final image with xz (-T0 -9e)..."
    xz -T0 -9e -f -k "${OUT_DIR}/rk3562-debian.img"
    cp -f "${OUT_DIR}/rk3562-debian.img.xz" "${OUTPUT_DIR}/update/update.img.xz"

    if [ -f "${OUT_DIR}/rootfs.ext4" ]; then
        ln -sfn "../out/rootfs.ext4" "${ROOT_DIR}/prebuilt_rootfs/rk3562_debian_rootfs.img"
    fi

    ensure_sdk_compat_layout
    
    echo "[+] Done! Image is available at ${OUT_DIR}/rk3562-debian.img"
    echo "[+] Compressed image is available at ${OUT_DIR}/rk3562-debian.img.xz"
    echo "[+] Firefly-compatible image path: ${OUTPUT_DIR}/update/update.img"
    echo "[+] Compressed Firefly-compatible image path: ${OUTPUT_DIR}/update/update.img.xz"
}

create_update_package() {
    echo "[*] Building offline update package..."
    local updater="${ROOT_DIR}/tools/make_update_tar.sh"
    if [ ! -x "${updater}" ]; then
        chmod +x "${updater}"
    fi
    "${updater}" "${OUTPUT_DIR}/update/update.tar.gz"
}

case "${CMD}" in
    check)
        check_deps
        ensure_sdk_compat_layout
        ;;
    lunch)
        ensure_sdk_compat_layout
        select_lunch
        ;;
    uboot)
        check_deps
        setup_dirs
        build_uboot
        ;;
    extboot)
        check_deps
        setup_dirs
        build_kernel
        ;;
    updateimg)
        verify_rootfs_profile
        create_image
        ;;
    updatepkg)
        verify_rootfs_profile
        create_update_package
        ;;
    compile)
        check_deps
        setup_dirs
        build_uboot
        build_kernel
        ;;
    rootfs)
        run_build_rootfs
        verify_rootfs_profile
        ;;
    image)
        verify_rootfs_profile
        create_image
        ;;
    all)
        check_deps
        setup_dirs
        build_uboot
        build_kernel
        run_build_rootfs
        verify_rootfs_profile
        create_image
        create_update_package
        ;;
    *)
        usage
        exit 1
        ;;
esac
