#!/bin/bash
set -e

export PATH="/usr/sbin:/sbin:$PATH"

# RK3562 Debian 13 Trixie Rootfs Builder

if [ "$EUID" -ne 0 ]; then
  echo "[-] This script must be run as root."
  exit 1
fi

if [ "$#" -gt 0 ]; then
  echo "[-] build_rootfs.sh builds rootfs only and does not accept build targets."
  echo "    Use ./build.sh all for a full image build, or ./build.sh image to pack an existing rootfs."
  exit 1
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT_DIR="${ROOT_DIR}/out"
ROOTFS_MNT="${OUT_DIR}/rootfs"
MODULES_DIR="${OUT_DIR}/modules_staging/lib/modules"
RKDEBIAN_DISPLAY_SERVER="${RKDEBIAN_DISPLAY_SERVER:-wayland}"
RKDEBIAN_CPU_GOVERNOR="${RKDEBIAN_CPU_GOVERNOR:-performance}"
RKDEBIAN_GPU_STACK="${RKDEBIAN_GPU_STACK:-mali}"
RKDEBIAN_UI_SESSION="${RKDEBIAN_UI_SESSION:-phosh}"
RKDEBIAN_MALI_GBM_PROVIDER="${RKDEBIAN_MALI_GBM_PROVIDER:-vendor}"
RKDEBIAN_PREINSTALL_FREETUBE="${RKDEBIAN_PREINSTALL_FREETUBE:-1}"
RKDEBIAN_MINIMIZE_IMAGE="${RKDEBIAN_MINIMIZE_IMAGE:-0}"

case "${RKDEBIAN_DISPLAY_SERVER}" in
    auto|wayland|x11) ;;
    *)
        echo "[-] Unsupported RKDEBIAN_DISPLAY_SERVER=${RKDEBIAN_DISPLAY_SERVER} (expected auto, wayland, or x11)."
        exit 1
        ;;
esac

case "${RKDEBIAN_CPU_GOVERNOR}" in
    performance|schedutil|ondemand|powersave|conservative|userspace) ;;
    *)
        echo "[-] Unsupported RKDEBIAN_CPU_GOVERNOR=${RKDEBIAN_CPU_GOVERNOR}."
        exit 1
        ;;
esac

case "${RKDEBIAN_GPU_STACK}" in
    mali|panfrost) ;;
    *)
        echo "[-] Unsupported RKDEBIAN_GPU_STACK=${RKDEBIAN_GPU_STACK} (expected mali or panfrost)."
        exit 1
        ;;
esac

case "${RKDEBIAN_UI_SESSION}" in
    phosh) ;;
    *)
        echo "[-] Unsupported RKDEBIAN_UI_SESSION=${RKDEBIAN_UI_SESSION} (expected phosh)."
        exit 1
        ;;
esac

case "${RKDEBIAN_MALI_GBM_PROVIDER}" in
    vendor|debian) ;;
    *)
        echo "[-] Unsupported RKDEBIAN_MALI_GBM_PROVIDER=${RKDEBIAN_MALI_GBM_PROVIDER} (expected vendor or debian)."
        exit 1
        ;;
esac

case "${RKDEBIAN_PREINSTALL_FREETUBE}" in
    0|1) ;;
    *)
        echo "[-] Unsupported RKDEBIAN_PREINSTALL_FREETUBE=${RKDEBIAN_PREINSTALL_FREETUBE} (expected 0 or 1)."
        exit 1
        ;;
esac

case "${RKDEBIAN_MINIMIZE_IMAGE}" in
    0|1) ;;
    *)
        echo "[-] Unsupported RKDEBIAN_MINIMIZE_IMAGE=${RKDEBIAN_MINIMIZE_IMAGE} (expected 0 or 1)."
        exit 1
        ;;
esac

echo "[*] Building Debian 13 Trixie arm64 rootfs..."
echo "[*] UI session: ${RKDEBIAN_UI_SESSION} | GPU stack: ${RKDEBIAN_GPU_STACK} | mali libgbm: ${RKDEBIAN_MALI_GBM_PROVIDER} | preinstall-freetube: ${RKDEBIAN_PREINSTALL_FREETUBE} | minimize: ${RKDEBIAN_MINIMIZE_IMAGE}"

chroot_cleanup() {
    local mount_path
    local cleaned=0

    while IFS= read -r mount_path; do
        [ -n "${mount_path}" ] || continue

        if [ "${cleaned}" -eq 0 ]; then
            echo "[*] Releasing stale chroot bind mounts..."
            cleaned=1
        fi

        umount -l "${mount_path}" 2>/dev/null || true
    done < <(
        findmnt -rn -o TARGET 2>/dev/null \
            | awk -v root="${ROOTFS_MNT}" '
                $0 == root || index($0, root "/") == 1 {
                    print length($0) "\t" $0
                }
            ' \
            | sort -rn \
            | cut -f2-
    )
}

chroot_cleanup

# Optional: force a fresh debootstrap rootfs to avoid stale package/config
# carry-over across iterative builds.
if [ "${RKDEBIAN_FORCE_CLEAN_ROOTFS:-0}" = "1" ]; then
    echo "[*] RKDEBIAN_FORCE_CLEAN_ROOTFS=1 -> removing existing rootfs tree..."
    rm -rf "${ROOTFS_MNT}"
fi

# 1. Run debootstrap
if [ ! -f "${ROOTFS_MNT}/etc/debian_version" ]; then
    echo "[*] Cleaning old rootfs..."
    rm -rf "${ROOTFS_MNT}"
    mkdir -p "${ROOTFS_MNT}"

    echo "[*] Running debootstrap first stage..."
    debootstrap --arch=arm64 --foreign trixie "${ROOTFS_MNT}" http://deb.debian.org/debian/

    echo "[*] Copying qemu-aarch64-static..."
    cp /usr/bin/qemu-aarch64-static "${ROOTFS_MNT}/usr/bin/"

    echo "[*] Running debootstrap second stage..."
    chmod +x "${ROOTFS_MNT}/debootstrap/debootstrap"
    chroot "${ROOTFS_MNT}" /debootstrap/debootstrap --second-stage
else
    echo "[*] Existing Debian 13 rootfs found. Skipping debootstrap..."
    echo "[*] Tip: set RKDEBIAN_FORCE_CLEAN_ROOTFS=1 for a fully fresh rebuild."
fi

# 2. Setup chroot mounts
echo "[*] Setting up chroot mounts..."
mkdir -p "${ROOTFS_MNT}/proc" "${ROOTFS_MNT}/sys" "${ROOTFS_MNT}/dev/pts"
mount --bind /proc    "${ROOTFS_MNT}/proc"
mount --bind /sys     "${ROOTFS_MNT}/sys"
mount --bind /dev     "${ROOTFS_MNT}/dev"
mount --bind /dev/pts "${ROOTFS_MNT}/dev/pts"
rm -f "${ROOTFS_MNT}/etc/resolv.conf"
cp /etc/resolv.conf "${ROOTFS_MNT}/etc/resolv.conf"

trap chroot_cleanup EXIT

# Crashed package installs can leave broken apt temp symlinks behind, which
# later confuse ownership repair in the outer build wrapper.
echo "[*] Cleaning stale apt/dpkg temp state..."
rm -rf "${ROOTFS_MNT}/tmp/apt-dpkg-install-"* 2>/dev/null || true
rm -rf "${ROOTFS_MNT}/var/tmp/apt-dpkg-install-"* 2>/dev/null || true

# 3. Configure Debian base
echo "[*] Configuring Debian base inside chroot..."

cat << 'CHROOT_EOF' > "${ROOTFS_MNT}/tmp/setup_debian.sh"
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# Ensure firmware repositories are available on Trixie.
cat > /etc/apt/sources.list << 'APT_SOURCES'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
APT_SOURCES

# Avoid man-db trigger permission issues on reused trees. man-db updates this
# cache as user "man", so root:root ownership can cause permission warnings.
mkdir -p /var/cache/man
if getent passwd man >/dev/null 2>&1; then
    chown -R man:root /var/cache/man 2>/dev/null || true
else
    chown -R root:root /var/cache/man 2>/dev/null || true
fi
find /var/cache/man -type d -exec chmod 0755 {} + 2>/dev/null || true
chmod g+s /var/cache/man 2>/dev/null || true
find /var/cache/man -type f -exec chmod 0644 {} + 2>/dev/null || true

# Update apt and install basic utilities
apt-get update
echo "[*] Recovering interrupted dpkg state (if any)..."
dpkg --configure -a || \
    echo "[!] Warning: dpkg configure step reported errors; continuing with apt repair."
apt-get -f install -y || \
    echo "[!] Warning: apt dependency repair failed; continuing with base package install."
apt-get install -y sudo curl wget nano vim openssh-server network-manager wpasupplicant iw wireless-tools \
    network-manager-gnome bluez blueman \
    xorg xserver-xorg xserver-xorg-input-libinput firefox-esr mesa-utils libgl1-mesa-dri mesa-vulkan-drivers \
    pipewire pipewire-audio pipewire-alsa pipewire-pulse wireplumber pavucontrol alsa-utils libasound2-plugins \
    pipewire-libcamera libcamera-ipa libcamera-v4l2 \
    gedit \
    zram-tools \
    plymouth plymouth-themes \
    libegl1 libgles2 libgbm1 libva2 libva-drm2 ffmpeg dbus \
    udev evtest pciutils usbutils \
    xinput libinput-tools \
    python3 python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 \
    python3-evdev \
    qt6-wayland \
    i2c-tools \
    iproute2 iputils-ping dnsutils locales tzdata upower power-profiles-daemon brightnessctl rfkill \
    vainfo vdpauinfo \
    wireless-regdb firmware-brcm80211 \
    gnome-themes-extra gnome-themes-extra-data adwaita-icon-theme \
    packagekit flatpak appstream xdg-desktop-portal \
    dolphin plasma-discover okular \
    gstreamer1.0-tools

# Install one policykit authentication agent. Package names differ across
# Debian releases, so try multiple providers in order.
polkit_agent_installed=0
for polkit_agent_pkg in policykit-1-gnome mate-polkit lxqt-policykit polkit-kde-agent-1; do
    pkg_ver=$(apt-cache policy "${polkit_agent_pkg}" 2>/dev/null | awk '/Candidate:/{print $2}')
    if [ -n "${pkg_ver}" ] && [ "${pkg_ver}" != "(none)" ]; then
        if apt-get install -y "${polkit_agent_pkg}"; then
            echo "[*] Installed polkit auth agent package: ${polkit_agent_pkg}"
            polkit_agent_installed=1
            break
        fi
    fi
done
if [ "${polkit_agent_installed}" -eq 0 ]; then
    echo "[!] Warning: no polkit auth-agent package available; GUI auth prompts may not work."
fi

# Remove stale cross-release apt source/pinning files from old builds so
# sources.list above is authoritative.
rm -f /etc/apt/sources.list.d/bookworm.list
rm -f /etc/apt/preferences.d/99-bookworm-pin
rm -f /etc/apt/sources.list.d/trixie.list
rm -f /etc/apt/preferences.d/99-trixie-pin
apt-get update -qq

# Remove stale desktop shells from reused rootfs trees so a non-clean build
# still converges to the Phosh profile.
stale_session_pkgs="$(
    dpkg-query -W -f='${Package}\n' | \
        grep -E '^(lomiri(|-.*)|mir-platform-graphics-.*|mir-graphics-drivers-desktop|plasma-.*|kwin-wayland|sddm(|-.*)|kde-plasma-desktop)$' | \
        grep -Ev '^plasma-discover(|-.*)$' || true
)"
if [ -n "${stale_session_pkgs}" ]; then
    echo "[*] Purging stale desktop/session packages: ${stale_session_pkgs//$'\n'/ }"
    apt-get purge -y ${stale_session_pkgs}
    apt-get autoremove -y --purge
fi

echo "[*] Installing Phosh session packages..."
apt-get install -y lightdm lightdm-gtk-greeter \
    phosh phoc phosh-mobile-settings phosh-mobile-tweaks phosh-plugins \
    squeekboard wlr-randr grim xwayland iio-sensor-proxy

# Prefer a modern terminal app over legacy xterm/uxterm launchers.
if apt-cache show kgx >/dev/null 2>&1; then
    apt-get install -y kgx
elif apt-cache show gnome-terminal >/dev/null 2>&1; then
    apt-get install -y gnome-terminal
else
    echo "[!] Warning: no modern terminal package found (kgx/gnome-terminal)."
fi

# Optional helpers for sandboxed apps and touch/desktop integration.
for optional_pkg in xdg-desktop-portal-gtk xdg-desktop-portal-gnome plasma-discover-backend-flatpak; do
    # Check candidate availability first to keep optional installs resilient
    # across mirror/package changes.
    pkg_ver=$(apt-cache policy "${optional_pkg}" 2>/dev/null \
              | awk '/Candidate:/{print $2}')
    if [ -n "${pkg_ver}" ] && [ "${pkg_ver}" != "(none)" ]; then
        apt-get install -y "${optional_pkg}" || \
            echo "[!] Warning: ${optional_pkg} install failed, skipping"
    else
        echo "[!] Warning: ${optional_pkg} not available, skipping"
    fi
done

# Camera bring-up helpers for quick on-device verification.
for camera_pkg in v4l-utils libcamera-tools; do
    pkg_ver=$(apt-cache policy "${camera_pkg}" 2>/dev/null | awk '/Candidate:/{print $2}')
    if [ -n "${pkg_ver}" ] && [ "${pkg_ver}" != "(none)" ]; then
        apt-get install -y "${camera_pkg}" || \
            echo "[!] Warning: ${camera_pkg} install failed, skipping"
    else
        echo "[!] Warning: ${camera_pkg} not available, skipping"
    fi
done

# Install Snapshot when available as the GUI camera app.
snapshot_ver=$(apt-cache policy snapshot 2>/dev/null | awk '/Candidate:/{print $2}')
if [ -n "${snapshot_ver}" ] && [ "${snapshot_ver}" != "(none)" ]; then
    apt-get install -y snapshot || \
        echo "[!] Warning: snapshot install failed, skipping"
else
    echo "[!] Warning: snapshot not available on current mirror."
fi

# Install Drawing when available as a touch-friendly paint app.
drawing_ver=$(apt-cache policy drawing 2>/dev/null | awk '/Candidate:/{print $2}')
if [ -n "${drawing_ver}" ] && [ "${drawing_ver}" != "(none)" ]; then
    apt-get install -y drawing || \
        echo "[!] Warning: drawing install failed, skipping"
else
    echo "[!] Warning: drawing not available on current mirror."
fi

# Ensure reused rootfs trees do not keep a previously installed Cheese stack.
if dpkg-query -W -f='${Status}' cheese 2>/dev/null | grep -q "install ok installed"; then
    echo "[*] Purging stale camera package: cheese"
    apt-get purge -y cheese || true
fi
rm -f /usr/share/dbus-1/services/org.gnome.Cheese.service \
      /etc/dconf/db/local.d/30-cheese-camera

# App store source: Flathub remote for Flatpak.
if command -v flatpak >/dev/null 2>&1; then
    flatpak remote-add --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo || \
            echo "[!] Warning: failed to add Flathub remote."

    # Keep heavy Flatpak apps optional to avoid inflating default image size.
    RKDEBIAN_PREINSTALL_FREETUBE="${RKDEBIAN_PREINSTALL_FREETUBE:-1}"
    freetube_ref="io.freetubeapp.FreeTube"
    if [ "${RKDEBIAN_PREINSTALL_FREETUBE}" = "1" ]; then
        if flatpak remote-info --system flathub "${freetube_ref}" >/dev/null 2>&1; then
            flatpak install --system -y --noninteractive flathub "${freetube_ref}" || \
                echo "[!] Warning: FreeTube Flatpak install failed, skipping."
        else
            echo "[!] Warning: FreeTube Flatpak (${freetube_ref}) not available, skipping."
        fi
    else
        # Reused rootfs trees may still contain old FreeTube installs.
        if flatpak info --system "${freetube_ref}" >/dev/null 2>&1; then
            echo "[*] Removing stale FreeTube Flatpak from reused rootfs..."
            flatpak uninstall --system -y "${freetube_ref}" >/dev/null 2>&1 || true
            flatpak uninstall --system -y --unused >/dev/null 2>&1 || true
        fi
        echo "[*] Skipping FreeTube Flatpak preinstall (RKDEBIAN_PREINSTALL_FREETUBE=0)."
    fi
fi

# Chromium is often smoother than Firefox on this board for YouTube playback.
if apt-cache show chromium >/dev/null 2>&1; then
    apt-get install -y chromium
else
    echo "[!] Warning: chromium package not available on current mirror."
fi

# Reused rootfs trees can carry over emulator/gaming packages from previous
# experiments. Purge them so mainline desktop images stay clean.
stale_retro_pkgs="$(
    dpkg-query -W -f='${Package}\n' | \
        grep -E '^(retroarch(|-assets)|libretro-.*|dolphin-emu(|-data)|emulationstation(|-dev)?|es-theme-.*|pegasus-frontend(|-.*)?|mupen64plus.*|ppsspp.*|pcsx2.*)$' || true
)"
if [ -n "${stale_retro_pkgs}" ]; then
    echo "[*] Purging stale retro-gaming packages: ${stale_retro_pkgs//$'\n'/ }"
    apt-get purge -y ${stale_retro_pkgs}
    apt-get autoremove -y --purge
fi

# NetworkManager rejects plugin modules unless owned by root.
find /usr/lib -type f -path '*/NetworkManager/*/libnm-*.so' \
    -exec chown root:root {} + 2>/dev/null || true
    
# Generate locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# Add default user
groupadd -f render
if ! id "chaos" &>/dev/null; then
    useradd -m -s /bin/bash chaos
    echo "chaos:chaos" | chpasswd
fi
usermod -aG sudo,video,audio,netdev,render,input chaos
install -d -m 0755 /etc/sudoers.d
cat > /etc/sudoers.d/10-chaos-nopasswd << 'SUDOERS_CHAOS'
chaos ALL=(ALL) NOPASSWD: ALL
SUDOERS_CHAOS
chmod 0440 /etc/sudoers.d/10-chaos-nopasswd
chown root:root /etc/sudoers.d/10-chaos-nopasswd
visudo -cf /etc/sudoers >/dev/null

# Set root password
echo "root:root" | chpasswd

# Setup NetworkManager
enable_if_installable() {
    local unit_name="$1"
    if systemctl cat "${unit_name}" 2>/dev/null | grep -q '^\[Install\]'; then
        systemctl enable "${unit_name}" >/dev/null 2>&1 || true
    fi
}

systemctl enable NetworkManager
enable_if_installable bluetooth.service
enable_if_installable upower.service
# This tablet has no cellular modem; keep WWAN stack disabled so Phosh does
# not show a cellular status path on the top bar.
systemctl disable ModemManager.service 2>/dev/null || true
systemctl mask ModemManager.service 2>/dev/null || true
# Select display manager: LightDM for Phosh.
rm -f /etc/systemd/system/display-manager.service
systemctl disable sddm 2>/dev/null || true
systemctl enable lightdm
enable_if_installable packagekit.service

# Enable compressed RAM swap to improve responsiveness on 4GB systems.
cat > /etc/default/zramswap << 'ZRAMCFG'
# RK3562 kernel currently supports: lzo, lzo-rle, zstd
ALGO=lzo-rle
PERCENT=50
PRIORITY=100
ZRAMCFG
systemctl enable zramswap.service || true

# Force NetworkManager to manage wlan interfaces on Debian.
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-rkdebian-managed.conf << 'NMCONF'
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=true

[keyfile]
unmanaged-devices=
NMCONF

# Keep interfaces minimal so NM can own Wi-Fi setup.
cat > /etc/network/interfaces << 'IFACES'
auto lo
iface lo inet loopback
IFACES

# Default Phosh WWAN backend away from ModemManager on non-cellular hardware.
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/20-rkdebian-phosh-wwan << 'PHOSH_WWAN_DCONF'
[sm/puri/phosh]
wwan-backend='ofono'
PHOSH_WWAN_DCONF

# Keep lockscreen enabled by default.
# (Older images disabled it as a temporary portrait-workaround.)
cat > /etc/dconf/db/local.d/21-rkdebian-phosh-lockscreen << 'PHOSH_LOCK_DCONF'
[org/gnome/desktop/screensaver]
lock-enabled=true

[org/gnome/desktop/lockdown]
disable-lock-screen=false
PHOSH_LOCK_DCONF

# Disable GSD power-button actions so logind + custom long-press handler own
# power-key policy without duplicate actions.
cat > /etc/dconf/db/local.d/22-rkdebian-power-button << 'PHOSH_POWERKEY_DCONF'
[org/gnome/settings-daemon/plugins/power]
power-button-action='nothing'
PHOSH_POWERKEY_DCONF
dconf update >/dev/null 2>&1 || true

# Automatically power adapters when bluetoothd starts.
if grep -q '^[#[:space:]]*AutoEnable=' /etc/bluetooth/main.conf 2>/dev/null; then
    sed -i 's/^[#[:space:]]*AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf
else
    printf '\n[Policy]\nAutoEnable=true\n' >> /etc/bluetooth/main.conf
fi

# Firefox launcher defaults for RK3562: prefer native Wayland + VAAPI and
# neutralize stale MOZ_X11_EGL values inherited from login environments.
if [ -f /usr/share/applications/firefox-esr.desktop ]; then
    sed -i -E 's|^Exec=.*firefox-esr.*$|Exec=env -u MOZ_X11_EGL MOZ_DISABLE_RDD_SANDBOX=1 MOZ_ENABLE_WAYLAND=1 MOZ_WAYLAND_USE_VAAPI=1 MOZ_DRM_DEVICE=/dev/dri/renderD128 LIBVA_DRIVER_NAME=rockchip /usr/lib/firefox-esr/firefox-esr %u|' \
        /usr/share/applications/firefox-esr.desktop || true
fi

# Configure a simple boot splash theme.
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    plymouth-set-default-theme spinner || true
fi
# Some Plymouth units are static on Debian and emit warnings when "enabled".
# Enable only units that actually advertise an [Install] section.
for ply_unit in plymouth-start.service plymouth-quit.service plymouth-quit-wait.service; do
    if systemctl cat "${ply_unit}" 2>/dev/null | grep -q '^\[Install\]'; then
        systemctl enable "${ply_unit}" >/dev/null 2>&1 || true
    fi
done

CHROOT_EOF

chmod +x "${ROOTFS_MNT}/tmp/setup_debian.sh"
if [ ! -f "${ROOTFS_MNT}/tmp/setup_debian.sh" ]; then
    echo "[-] Missing chroot setup script: ${ROOTFS_MNT}/tmp/setup_debian.sh"
    exit 1
fi
# Execute chroot setup via bash explicitly to avoid shebang/direct-exec edge cases.
if ! chroot "${ROOTFS_MNT}" env \
    RKDEBIAN_UI_SESSION="${RKDEBIAN_UI_SESSION}" \
    RKDEBIAN_PREINSTALL_FREETUBE="${RKDEBIAN_PREINSTALL_FREETUBE}" \
    RKDEBIAN_MINIMIZE_IMAGE="${RKDEBIAN_MINIMIZE_IMAGE}" \
    QEMU_RESERVED_VA=0x4000000000 \
    /bin/bash /tmp/setup_debian.sh; then
    echo "[-] Error: chroot setup script failed (/tmp/setup_debian.sh)."
    exit 1
fi
rm "${ROOTFS_MNT}/tmp/setup_debian.sh"

# Do not silently continue when the requested Phosh session is missing.
if [ ! -f "${ROOTFS_MNT}/usr/share/wayland-sessions/phosh.desktop" ]; then
    echo "[-] Error: RKDEBIAN_UI_SESSION=phosh requested, but phosh.desktop is missing in rootfs."
    echo "    Aborting image build to avoid shipping a wrong session profile."
    exit 1
fi

# Ensure privilege-escalation binaries/configs keep root ownership and setuid/setperm bits.
chroot "${ROOTFS_MNT}" chown root:root /etc/sudo.conf /usr/bin/sudo || true
chroot "${ROOTFS_MNT}" chmod 4755 /usr/bin/sudo || true
chroot "${ROOTFS_MNT}" chown root:root /etc/sudoers /etc/sudoers.d || true
chroot "${ROOTFS_MNT}" chmod 0440 /etc/sudoers || true
chroot "${ROOTFS_MNT}" chmod 0755 /etc/sudoers.d || true
if [ -d "${ROOTFS_MNT}/etc/sudoers.d" ]; then
    chroot "${ROOTFS_MNT}" chown -R root:root /etc/sudoers.d || true
    find "${ROOTFS_MNT}/etc/sudoers.d" -type f -exec chmod 0440 {} +
fi
if [ -e "${ROOTFS_MNT}/bin/su" ]; then
    chroot "${ROOTFS_MNT}" chown root:root /bin/su || true
    chroot "${ROOTFS_MNT}" chmod 4755 /bin/su || true
fi
if [ -e "${ROOTFS_MNT}/usr/bin/su" ]; then
    chroot "${ROOTFS_MNT}" chown root:root /usr/bin/su || true
    chroot "${ROOTFS_MNT}" chmod 4755 /usr/bin/su || true
fi
if [ -e "${ROOTFS_MNT}/usr/bin/pkexec" ]; then
    chroot "${ROOTFS_MNT}" chown root:root /usr/bin/pkexec || true
    chroot "${ROOTFS_MNT}" chmod 4755 /usr/bin/pkexec || true
fi
if [ -e "${ROOTFS_MNT}/usr/lib/polkit-1" ]; then
    chroot "${ROOTFS_MNT}" chown root:root /usr/lib/polkit-1 || true
    chroot "${ROOTFS_MNT}" chmod 0755 /usr/lib/polkit-1 || true
fi
if [ -e "${ROOTFS_MNT}/usr/lib/polkit-1/polkitd" ]; then
    chroot "${ROOTFS_MNT}" chown root:root /usr/lib/polkit-1/polkitd || true
    chroot "${ROOTFS_MNT}" chmod 0755 /usr/lib/polkit-1/polkitd || true
fi
if [ -e "${ROOTFS_MNT}/usr/lib/polkit-1/polkit-agent-helper-1" ]; then
    chroot "${ROOTFS_MNT}" chown root:root /usr/lib/polkit-1/polkit-agent-helper-1 || true
    chroot "${ROOTFS_MNT}" chmod 4755 /usr/lib/polkit-1/polkit-agent-helper-1 || true
fi
# 4. Install Kernel Modules
if [ -d "${MODULES_DIR}" ]; then
    echo "[*] Installing kernel modules..."
    mkdir -p "${ROOTFS_MNT}/lib/modules"
    cp -a --no-preserve=ownership "${MODULES_DIR}"/* "${ROOTFS_MNT}/lib/modules/"
else
    echo "[!] Warning: kernel modules not found at ${MODULES_DIR}"
fi

# 5. Install GPU/MPP packages
echo "[*] Installing GPU and MPP packages..."
if [ -d "${ROOT_DIR}/debs" ]; then
    if compgen -G "${ROOT_DIR}/debs/*.deb" > /dev/null; then
        mkdir -p "${ROOTFS_MNT}/tmp/debs"
        cp "${ROOT_DIR}/debs"/*.deb "${ROOTFS_MNT}/tmp/debs/"
        if ! chroot "${ROOTFS_MNT}" env RKDEBIAN_GPU_STACK="${RKDEBIAN_GPU_STACK}" bash -c '
set -e

# Install non-Mali local packages first.
non_mali_debs="$(find /tmp/debs -maxdepth 1 -type f -name "*.deb" ! -name "libmali*.deb" -print)"
if [ -n "${non_mali_debs}" ]; then
    dpkg -i ${non_mali_debs} || apt-get -f install -y
fi

# Mesa/Panfrost stack: ensure no libmali userspace package is installed.
if [ "${RKDEBIAN_GPU_STACK:-mali}" = "panfrost" ]; then
    existing_mali_pkgs="$(dpkg -l | awk '"'"'/^ii/ && $2 ~ /^libmali-/ {print $2}'"'"')"
    if [ -n "${existing_mali_pkgs}" ]; then
        apt-get purge -y ${existing_mali_pkgs}
        apt-get -f install -y
    fi
else
    # Phosh is Wayland-first: prefer wayland-gbm blobs.
    # Keep x11-wayland/x11 variants as fallback when wayland-gbm is unavailable.
    selected_mali_deb=""
    for candidate in \
        /tmp/debs/libmali*-wayland-gbm*.deb \
        /tmp/debs/libmali*-x11-wayland-gbm*.deb \
        /tmp/debs/libmali*-x11-gbm*.deb \
        /tmp/debs/libmali*.deb; do
        [ -e "${candidate}" ] || continue
        selected_mali_deb="${candidate}"
        break
    done

    if [ -n "${selected_mali_deb}" ]; then
        selected_mali_pkg="$(dpkg-deb -f "${selected_mali_deb}" Package)"

        # Ensure only the selected libmali family remains installed.
        existing_mali_pkgs="$(dpkg -l | awk '"'"'/^ii/ && $2 ~ /^libmali-/ {print $2}'"'"')"
        if [ -n "${existing_mali_pkgs}" ]; then
            apt-get purge -y ${existing_mali_pkgs}
            apt-get -f install -y
        fi

        dpkg -i "${selected_mali_deb}" || apt-get -f install -y
        if ! dpkg -s "${selected_mali_pkg}" 2>/dev/null | grep -q "^Status: install ok installed$"; then
            echo "[-] Error: failed to install expected Mali package: ${selected_mali_pkg}"
            dpkg -l | awk '"'"'/^ii/ && $2 ~ /^libmali-/ {print $2, $3}'"'"' || true
            exit 1
        fi
    fi
fi
        '; then
            echo "[-] Error: failed to install local GPU/MPP packages in chroot."
            rm -rf "${ROOTFS_MNT}/tmp/debs"
            exit 1
        fi
        rm -rf "${ROOTFS_MNT}/tmp/debs"
    else
        echo "[!] Warning: No .deb files found in ${ROOT_DIR}/debs"
    fi
fi

# 5b. Finalize GPU userspace stack.
if [ "${RKDEBIAN_GPU_STACK}" = "panfrost" ]; then
    echo "[*] Finalizing Mesa/Panfrost userspace stack..."
    rm -rf "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/mali"
    rm -f "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/libmali.so" \
          "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/libmali.so.1" \
          "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/libmali-hook.so" \
          "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/libmali-hook.so.1" \
          "${ROOTFS_MNT}/etc/ld.so.conf.d/00-aarch64-mali.conf"
    chroot "${ROOTFS_MNT}" ldconfig
else
    # Mali userspace stack. Default is to keep vendor libgbm as shipped by the
    # selected libmali package. If needed, callers can force Debian libgbm via
    # RKDEBIAN_MALI_GBM_PROVIDER=debian.
    if compgen -G "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/mali/libmali*.so" > /dev/null || \
       [ -e "${ROOTFS_MNT}/lib/aarch64-linux-gnu/libmali.so.1" ] || \
       [ -e "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/libmali.so.1" ] || \
       [ -e "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/mali/libgbm.so.1" ]; then
        mali_dir="${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/mali"
        mali_gbm_backup="${mali_dir}/.libgbm.so.1.rkbak"

        if [ "${RKDEBIAN_MALI_GBM_PROVIDER}" = "debian" ]; then
            echo "[*] Forcing Mali libgbm path to Debian libgbm (override enabled)..."

            if [ -e "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/libgbm.so.1" ]; then
                if [ -e "${mali_dir}/libgbm.so.1" ] && [ ! -e "${mali_gbm_backup}" ]; then
                    cp -a "${mali_dir}/libgbm.so.1" "${mali_gbm_backup}"
                fi

                # Drop legacy backup names that match lib*.so*; ldconfig can
                # relink libgbm.so.1 back to them and undo the intended pin.
                rm -f "${mali_dir}/libgbm.so.1.rkbak"
                ln -sfn /usr/lib/aarch64-linux-gnu/libgbm.so.1 "${mali_dir}/libgbm.so.1"
                ln -sfn libgbm.so.1 "${mali_dir}/libgbm.so"
            fi
        else
            echo "[*] Keeping vendor Mali libgbm (default)..."

            if [ -e "${mali_gbm_backup}" ]; then
                cp -af "${mali_gbm_backup}" "${mali_dir}/libgbm.so.1"
            fi
            ln -sfn libgbm.so.1 "${mali_dir}/libgbm.so"
        fi

        chroot "${ROOTFS_MNT}" ldconfig
    else
        echo "[!] Warning: Mali userspace package not detected; skipping Mali-specific GBM setup."
    fi
fi

# 6. Install WiFi/BT firmware
echo "[*] Installing WiFi and Bluetooth firmware..."
mkdir -p "${ROOTFS_MNT}/lib/firmware"
mkdir -p "${ROOTFS_MNT}/vendor/etc/firmware"
if [ -d "${ROOT_DIR}/wifi" ]; then
    find "${ROOT_DIR}/wifi" -maxdepth 3 -type f \( \
        -name "*.bin" -o -name "*.txt" -o -name "*.clm_blob" -o -name "*.hcd" -o -name "*.ini" \) \
        -exec cp -f {} "${ROOTFS_MNT}/lib/firmware/" \; 2>/dev/null || true
fi
if [ -d "${ROOT_DIR}/overlay/firmware" ]; then
    cp -a --no-preserve=ownership "${ROOT_DIR}/overlay/firmware/." "${ROOTFS_MNT}/lib/firmware/" 2>/dev/null || true
fi
# Bluetooth NV configuration files
if [ -d "${ROOT_DIR}/overlay/drivers/net/wireless/ea6621q/swtbt4l/" ]; then
    cp -f "${ROOT_DIR}/overlay/drivers/net/wireless/ea6621q/swtbt4l/"*.nvbin "${ROOTFS_MNT}/lib/firmware/" 2>/dev/null || true
fi

# BCMDHD default firmware paths (kernel config points to /vendor/etc/firmware)
BCM_FW=$(find "${ROOTFS_MNT}/lib/firmware" -type f \( -name "*43455*bin" -o -name "*ap6255*bin" \) | head -n1 || true)
BCM_NVRAM=$(find "${ROOTFS_MNT}/lib/firmware" -type f \( -name "*43455*txt" -o -name "*ap6255*txt" -o -name "*nvram*.txt" \) | head -n1 || true)
BCM_CLM=$(find "${ROOTFS_MNT}/lib/firmware" -type f -name "*.clm_blob" | head -n1 || true)

if [ -n "${BCM_FW}" ]; then
    cp -f "${BCM_FW}" "${ROOTFS_MNT}/vendor/etc/firmware/fw_bcmdhd.bin"
fi
if [ -n "${BCM_NVRAM}" ]; then
    cp -f "${BCM_NVRAM}" "${ROOTFS_MNT}/vendor/etc/firmware/nvram.txt"
fi
if [ -n "${BCM_CLM}" ]; then
    cp -f "${BCM_CLM}" "${ROOTFS_MNT}/vendor/etc/firmware/bcmdhd_clm.blob"
fi

# Auto-load bluetooth driver module
mkdir -p "${ROOTFS_MNT}/etc/modules-load.d/"
echo "skwbt" > "${ROOTFS_MNT}/etc/modules-load.d/skwbt.conf"

# 7. Add Mali GPU udev rules
echo "[*] Adding Mali GPU udev rules..."
mkdir -p "${ROOTFS_MNT}/etc/udev/rules.d"
tee "${ROOTFS_MNT}/etc/udev/rules.d/99-mali.rules" > /dev/null << 'UDEV_MALI'
KERNEL=="mali0", GROUP="video", MODE="0666"
KERNEL=="rga", GROUP="video", MODE="0666"
SUBSYSTEM=="dma_heap", MODE="0666"
UDEV_MALI

# Allow desktop users in video group to access Rockchip media devices.
tee "${ROOTFS_MNT}/etc/udev/rules.d/98-rockchip-mpp.rules" > /dev/null << 'UDEV_MPP'
KERNEL=="mpp_service", GROUP="video", MODE="0660"
KERNEL=="rkvdec*", GROUP="video", MODE="0660"
KERNEL=="rkvenc*", GROUP="video", MODE="0660"
KERNEL=="vepu*", GROUP="video", MODE="0660"
KERNEL=="vdpu*", GROUP="video", MODE="0660"
UDEV_MPP

echo "[*] Adding backlight permission rule..."
mkdir -p "${ROOTFS_MNT}/usr/local/sbin"
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-backlight-setup.sh" << 'RK_BACKLIGHT_SETUP'
#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin

for backlight in /sys/class/backlight/*; do
    [ -d "${backlight}" ] || continue
    for attr in brightness bl_power; do
        file="${backlight}/${attr}"
        [ -e "${file}" ] || continue
        chgrp video "${file}" 2>/dev/null || true
        chmod g+w "${file}" 2>/dev/null || true
    done
done

exit 0
RK_BACKLIGHT_SETUP
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-backlight-setup.sh"

tee "${ROOTFS_MNT}/etc/udev/rules.d/90-backlight-permissions.rules" > /dev/null << 'UDEV_BACKLIGHT'
ACTION=="add|change", SUBSYSTEM=="backlight", RUN+="/usr/local/sbin/rk-backlight-setup.sh"
UDEV_BACKLIGHT

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-backlight-setup.service" << 'RK_BACKLIGHT_UNIT'
[Unit]
Description=Fix backlight permissions for desktop control
After=systemd-udev-settle.service local-fs.target
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-backlight-setup.sh

[Install]
WantedBy=multi-user.target
RK_BACKLIGHT_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rk-backlight-setup.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/rk-backlight-setup.service"

echo "[*] Adding touchscreen input rule..."
tee "${ROOTFS_MNT}/etc/udev/rules.d/99-touchscreen-gsl3673.rules" > /dev/null << 'UDEV_TS'
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="gsl3673", ENV{ID_INPUT}="1", ENV{ID_INPUT_TOUCHSCREEN}="1"
UDEV_TS

mkdir -p "${ROOTFS_MNT}/etc/X11/xorg.conf.d"
cat > "${ROOTFS_MNT}/etc/X11/xorg.conf.d/40-gsl3673-touchscreen.conf" << 'XORG_TS'
Section "InputClass"
    Identifier "gsl3673 touchscreen"
    MatchProduct "gsl3673"
    MatchIsTouchscreen "on"
    Driver "libinput"
    # Keep touch aligned with default X11 landscape-right panel orientation.
    Option "CalibrationMatrix" "0 1 0 -1 0 1 0 0 1"
EndSection
XORG_TS

cat > "${ROOTFS_MNT}/etc/X11/xorg.conf.d/30-panel-landscape.conf" << 'XORG_LANDSCAPE'
Section "Monitor"
    Identifier "DSI-1"
    Option "Rotate" "right"
EndSection

Section "Monitor"
    Identifier "eDP-1"
    Option "Rotate" "right"
EndSection

Section "Monitor"
    Identifier "LVDS-1"
    Option "Rotate" "right"
EndSection
XORG_LANDSCAPE

cat > "${ROOTFS_MNT}/etc/X11/xorg.conf.d/20-modesetting-rockchip.conf" << 'XORG_GPU'
Section "Device"
    Identifier "Rockchip Graphics"
    Driver "modesetting"
    # glamor is enabled for 2D acceleration.
    # NOTE: xrandr --rotate crashes the X server with the Mali BSP blob because
    # glamor's shadow-framebuffer rotation path is incompatible with this driver.
    # Screen rotation on X11 is intentionally disabled in the tray app; use a
    # Wayland session for smooth, crash-free rotation instead.
    Option "AccelMethod" "glamor"
    Option "DRI" "3"
EndSection
XORG_GPU

# Build rockchip_drv_video.so (Rockchip VAAPI driver) inside the chroot.
# Sources: sujit-168/rk_hw_base (MPP+RGA middleware) and sujit-168/rk_vaapi_driver.
# librga prebuilt (aarch64) is pulled from airockchip/librga.
echo "[*] Building Rockchip VAAPI driver inside chroot..."
cat > "${ROOTFS_MNT}/tmp/build_vaapi.sh" << 'BUILD_VAAPI_EOF'
#!/bin/bash
set -e
cd /tmp

# Install build dependencies for VAAPI driver
mkdir -p /var/cache/man
if getent passwd man >/dev/null 2>&1; then
    chown -R man:root /var/cache/man 2>/dev/null || true
else
    chown -R root:root /var/cache/man 2>/dev/null || true
fi
find /var/cache/man -type d -exec chmod 0755 {} + 2>/dev/null || true
chmod g+s /var/cache/man 2>/dev/null || true
find /var/cache/man -type f -exec chmod 0644 {} + 2>/dev/null || true

apt-get install -y --no-install-recommends git build-essential libva-dev libdrm-dev pkg-config

# Install librga prebuilt + headers from airockchip/librga
if [ ! -f /usr/lib/aarch64-linux-gnu/librga.so ]; then
    echo "[*] Fetching librga..."
    git clone --depth=1 https://github.com/airockchip/librga /tmp/librga_src
    cp /tmp/librga_src/libs/Linux/gcc-aarch64/librga.so /usr/lib/aarch64-linux-gnu/
    # Create SONAME symlink if the binary has one embedded
    SONAME=$(objdump -p /usr/lib/aarch64-linux-gnu/librga.so 2>/dev/null | awk '/SONAME/{print $2}')
    if [ -n "$SONAME" ] && [ "$SONAME" != "librga.so" ]; then
        ln -sf librga.so "/usr/lib/aarch64-linux-gnu/$SONAME"
    fi
    mkdir -p /usr/include/rga
    cp /tmp/librga_src/include/*.h /usr/include/rga/
    ldconfig
    rm -rf /tmp/librga_src
fi

# Build rk_hw_base middleware
if [ ! -f /usr/lib/aarch64-linux-gnu/librk_hw_base.so ]; then
    echo "[*] Building rk_hw_base..."
    git clone --depth=1 https://github.com/sujit-168/rk_hw_base /tmp/rk_hw_base
    cd /tmp/rk_hw_base
    make CFLAGS="-I./include -I/usr/include/rockchip -I/usr/include/rga -fPIC -Wall -O2" \
         LDFLAGS="-shared -L/usr/lib/aarch64-linux-gnu"
    cp lib/librk_hw_base.so /usr/lib/aarch64-linux-gnu/
    mkdir -p /usr/include/rk_hw_base
    cp include/*.h /usr/include/rk_hw_base/
    ldconfig
    cd /tmp
fi

# Build rockchip VAAPI driver
if [ ! -f /usr/lib/aarch64-linux-gnu/dri/rockchip_drv_video.so ]; then
    echo "[*] Building rockchip_drv_video.so..."
    git clone --depth=1 https://github.com/sujit-168/rk_vaapi_driver /tmp/rk_vaapi_driver
    # Ensure rk_hw_base sibling is present (may be missing on re-run if already installed)
    [ -d /tmp/rk_hw_base ] || git clone --depth=1 https://github.com/sujit-168/rk_hw_base /tmp/rk_hw_base
    cd /tmp/rk_vaapi_driver
    make
    mkdir -p /usr/lib/aarch64-linux-gnu/dri
    cp lib/rockchip_drv_video.so /usr/lib/aarch64-linux-gnu/dri/
    ldconfig
    cd /tmp
    rm -rf /tmp/rk_vaapi_driver /tmp/rk_hw_base
fi

# Clean up build-only dependencies
apt-get purge -y git build-essential libva-dev libdrm-dev pkg-config 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

echo "[+] Rockchip VAAPI driver ready."
BUILD_VAAPI_EOF
chmod +x "${ROOTFS_MNT}/tmp/build_vaapi.sh"
if chroot "${ROOTFS_MNT}" /tmp/build_vaapi.sh; then
    echo "[*] VAAPI helper finished."
else
    echo "[!] Warning: VAAPI driver build failed; hardware video decode may be unavailable."
fi
rm -f "${ROOTFS_MNT}/tmp/build_vaapi.sh"

echo "[*] Adding Firefox acceleration defaults..."
mkdir -p "${ROOTFS_MNT}/usr/lib/firefox-esr/defaults/pref"
FF_VAAPI_ENABLED="false"
if [ -f "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/dri/rockchip_drv_video.so" ]; then
    FF_VAAPI_ENABLED="true"
    cat > "${ROOTFS_MNT}/usr/lib/firefox-esr/defaults/pref/rk3562-gfx.js" << 'FIREFOX_PREFS_HW'
pref("media.hardware-video-decoding.enabled", true);
pref("media.hardware-video-decoding.force-enabled", true);
pref("media.ffmpeg.vaapi.enabled", true);
pref("media.ffmpeg.dmabuf-textures.enabled", true);
pref("media.rdd-ffmpeg.enabled", true);
pref("media.ffvpx.enabled", false);
pref("media.webm.enabled", false);
pref("media.mediasource.webm.enabled", false);
pref("media.av1.enabled", false);
pref("media.mediasource.av1.enabled", false);
pref("media.mediasource.vp9.enabled", false);
FIREFOX_PREFS_HW
else
    echo "[!] Warning: rockchip_drv_video.so missing; using Firefox software-video fallback profile."
    cat > "${ROOTFS_MNT}/usr/lib/firefox-esr/defaults/pref/rk3562-gfx.js" << 'FIREFOX_PREFS_SW'
pref("media.hardware-video-decoding.enabled", false);
pref("media.hardware-video-decoding.force-enabled", false);
pref("media.ffmpeg.vaapi.enabled", false);
pref("media.ffmpeg.dmabuf-textures.enabled", false);
pref("media.rdd-ffmpeg.enabled", true);
pref("media.ffvpx.enabled", false);
pref("media.mediasource.enabled", false);
pref("media.webm.enabled", false);
pref("media.mediasource.webm.enabled", false);
pref("media.av1.enabled", false);
pref("media.mediasource.av1.enabled", false);
pref("media.mediasource.vp9.enabled", false);
FIREFOX_PREFS_SW
fi

# Keep Firefox environment deterministic across rebuilds.
touch "${ROOTFS_MNT}/etc/environment"
sed -i '/^MOZ_DISABLE_RDD_SANDBOX=/d;/^MOZ_X11_EGL=/d;/^MOZ_WEBRENDER=/d' \
    "${ROOTFS_MNT}/etc/environment" || true
echo "MOZ_DISABLE_RDD_SANDBOX=1" >> "${ROOTFS_MNT}/etc/environment"

# Auto-install h264ify on first Firefox run to keep YouTube on H.264 streams.
mkdir -p "${ROOTFS_MNT}/usr/lib/firefox-esr/distribution"
cat > "${ROOTFS_MNT}/usr/lib/firefox-esr/distribution/policies.json" << 'FIREFOX_POLICIES'
{
  "policies": {
    "Extensions": {
      "Install": [
        "https://addons.mozilla.org/firefox/downloads/latest/h264ify/latest.xpi"
      ]
    }
  }
}
FIREFOX_POLICIES

# ── Custom Plymouth boot splash ────────────────────────────────────────────
# Replaces the plain black screen with a navy gradient, "RK3562 / Debian
# GNU/Linux" text, a faded divider line, and 5 pulsing dots.
# PNG assets are generated with pure Python (no PIL dependency).
echo "[*] Installing custom Plymouth boot splash..."
THEME_DIR="${ROOTFS_MNT}/usr/share/plymouth/themes/rkdebian"
mkdir -p "${THEME_DIR}"

# dot.png — 14×14 soft-edged white circle for the loading dots
python3 - "${THEME_DIR}/dot.png" << 'PYGEN'
import sys, zlib, struct

def write_png(path, w, h, rows_rgba):
    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xffffffff
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)
    raw = b''.join(b'\x00' + bytes(r) for r in rows_rgba)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))

W = H = 14
cx = cy = W / 2.0
r  = W / 2.0 - 1.0
rows = []
for y in range(H):
    row = []
    for x in range(W):
        d     = ((x + 0.5 - cx)**2 + (y + 0.5 - cy)**2)**0.5
        alpha = min(255, max(0, int((r - d) * 90)))
        row  += [255, 255, 255, alpha]
    rows.append(row)
write_png(sys.argv[1], W, H, rows)
PYGEN

# line.png — 280×2 white bar that fades at both edges (decorative divider)
python3 - "${THEME_DIR}/line.png" << 'PYGEN'
import sys, zlib, struct

def write_png(path, w, h, rows_rgba):
    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xffffffff
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)
    raw = b''.join(b'\x00' + bytes(r) for r in rows_rgba)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))

W, H = 280, 2
rows = []
for y in range(H):
    row = []
    for x in range(W):
        fade  = min(x, W - x) / 28.0
        alpha = min(255, int(55 * min(1.0, fade)))
        row  += [255, 255, 255, alpha]
    rows.append(row)
write_png(sys.argv[1], W, H, rows)
PYGEN

# splash.png — custom boot logo from repository root
if [ ! -f "${ROOT_DIR}/splash.png" ]; then
    echo "[-] Error: missing ${ROOT_DIR}/splash.png (required for Plymouth logo)."
    exit 1
fi
install -m 0644 "${ROOT_DIR}/splash.png" "${THEME_DIR}/splash.png"
mkdir -p "${ROOTFS_MNT}/usr/share/backgrounds/rkdebian"
install -m 0644 "${ROOT_DIR}/splash.png" \
    "${ROOTFS_MNT}/usr/share/backgrounds/rkdebian/splash.png"

# Static framebuffer logo shown while booting. This bypasses Plymouth, which
# currently crashes on this Trixie + RK3562 stack.
mkdir -p "${ROOTFS_MNT}/usr/local/sbin" \
         "${ROOTFS_MNT}/etc/systemd/system" \
         "${ROOTFS_MNT}/etc/systemd/system/graphical.target.wants"
cat > "${ROOTFS_MNT}/usr/local/sbin/boot-fb-logo.sh" << 'BOOT_FB_LOGO'
#!/bin/sh
set -eu

IMG="/usr/share/plymouth/themes/rkdebian/splash.png"
FB="/dev/fb0"

[ -r "$IMG" ] || exit 0
command -v ffmpeg >/dev/null 2>&1 || exit 0

# Wait briefly for framebuffer device.
i=0
while [ $i -lt 40 ]; do
    [ -w "$FB" ] && break
    i=$((i + 1))
    sleep 0.1
done
[ -w "$FB" ] || exit 0

W=800
H=1280
if [ -r /sys/class/graphics/fb0/virtual_size ]; then
    VS="$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || true)"
    case "$VS" in
        *,*) W="${VS%%,*}"; H="${VS##*,}" ;;
    esac
fi

# The panel is rotated by kernel cmdline; rotate logo into expected orientation.
ROTATE_FILTER="transpose=1"

# Draw a centered, padded static splash. Repeat to survive early mode changes.
N=0
while [ $N -lt 5 ]; do
    ffmpeg -nostdin -hide_banner -loglevel error -y \
        -i "$IMG" -frames:v 1 \
        -vf "${ROTATE_FILTER},scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2" \
        -pix_fmt bgra -f fbdev "$FB" >/dev/null 2>&1 || true
    N=$((N + 1))
    sleep 0.2
done

exit 0
BOOT_FB_LOGO
chmod +x "${ROOTFS_MNT}/usr/local/sbin/boot-fb-logo.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/boot-fb-logo.service" << 'BOOT_FB_LOGO_UNIT'
[Unit]
Description=Draw static boot logo on framebuffer
After=systemd-udev-settle.service
Before=display-manager.service lightdm.service
ConditionPathExists=/dev/fb0

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/boot-fb-logo.sh
TimeoutStartSec=15

[Install]
WantedBy=graphical.target
BOOT_FB_LOGO_UNIT
ln -sfn /etc/systemd/system/boot-fb-logo.service \
    "${ROOTFS_MNT}/etc/systemd/system/graphical.target.wants/boot-fb-logo.service"

# Theme descriptor
cat > "${THEME_DIR}/rkdebian.plymouth" << 'PLYMOUTH_DESC'
[Plymouth Theme]
Name=rkdebian
Description=RK3562 Debian boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/rkdebian
ScriptFile=/usr/share/plymouth/themes/rkdebian/rkdebian.script
PLYMOUTH_DESC

# Animation script — runs inside Plymouth on the framebuffer
cat > "${THEME_DIR}/rkdebian.script" << 'PLYMOUTH_SCRIPT'
W = Window.GetWidth();
H = Window.GetHeight();

# Solid black background
Window.SetBackgroundTopColor(0.00, 0.00, 0.00);
Window.SetBackgroundBottomColor(0.00, 0.00, 0.00);

# ── Logo ───────────────────────────────────────────────────────────────────
logo_base = Image("splash.png");
logo_scale_w = (W * 0.78) / logo_base.GetWidth();
logo_scale_h = (H * 0.45) / logo_base.GetHeight();
logo_scale = Math.Min(logo_scale_w, logo_scale_h);
if (logo_scale > 1.0) logo_scale = 1.0;
logo = logo_base.Scale(logo_base.GetWidth() * logo_scale,
                       logo_base.GetHeight() * logo_scale);
logo_spr = Sprite();
logo_spr.SetImage(logo);
logo_spr.SetX(Math.Int(W / 2 - logo.GetWidth() / 2));
logo_spr.SetY(Math.Int(H * 0.18));

# ── Pulsing dot loader (5 dots, wave ripple) ───────────────────────────────
N      = 5;
STEP   = 22;
DOT_Y  = Math.Int(H * 0.73);
ORIGIN = Math.Int(W / 2 - (N - 1) * STEP / 2);

dot_img = Image("dot.png");
for (i = 0; i < N; i++) {
    dot[i] = Sprite();
    dot[i].SetImage(dot_img);
    dot[i].SetX(ORIGIN + i * STEP - Math.Int(dot_img.GetWidth() / 2));
    dot[i].SetY(DOT_Y);
    dot[i].SetOpacity(0.15);
}

tick = 0;
fun animate() {
    tick++;
    peak = Math.Int(tick / 7) % N;
    for (i = 0; i < N; i++) {
        diff = i - peak;
        if (diff < 0) diff = -diff;
        opacity = 1.0 - diff * 0.25;
        if (opacity < 0.10) opacity = 0.10;
        dot[i].SetOpacity(opacity);
    }
}
Plymouth.SetRefreshFunction(animate);
PLYMOUTH_SCRIPT

# Activate the theme (overrides the 'spinner' set earlier in the chroot)
chroot "${ROOTFS_MNT}" plymouth-set-default-theme rkdebian 2>/dev/null || \
    echo "[!] Warning: could not set Plymouth theme; 'spinner' will be used"

# Add Chromium hardware acceleration flags.
echo "[*] Adding Chromium acceleration flags..."
mkdir -p "${ROOTFS_MNT}/etc/chromium.d"
if [ "${FF_VAAPI_ENABLED}" = "true" ]; then
    cat > "${ROOTFS_MNT}/etc/chromium.d/rk3562-hw-accel" << 'CHROMIUM_HW_FLAGS'
# RK3562 hardware acceleration — sourced by /usr/bin/chromium wrapper
# Let Chromium select its default GL backend for this build.
# On Debian Chromium arm64, forcing --use-gl=egl can trigger GPU init fallback.
# rockchip VAAPI decode is available but has been unstable on YouTube with
# newer Chromium builds; default to software decode for reliability.
export LIBVA_DRIVER_NAME=rockchip
export LIBVA_DRIVERS_PATH=/usr/lib/aarch64-linux-gnu/dri
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ozone-platform=wayland"
# Chromium 146 on RK3562 + Wayland can auto-pick Vulkan and fail window
# startup; force non-Vulkan rendering for reliable launch.
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-vulkan"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-gpu-rasterization"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-gpu-compositing"
# Avoid GNOME keyring first-launch password prompt on autologin images.
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --password-store=basic"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-accelerated-video-decode"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiIgnoreDriverChecks,UseChromeOSDirectVideoDecoder"
# RK3562 fallback safety profile: software compositing is slower but avoids
# GPU process crashes seen on some YouTube/Wayland workloads.
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-gpu"
# Optional (faster but less stable on some images): enable VAAPI decode
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-accelerated-video-decode"
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiIgnoreDriverChecks"
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-features=UseChromeOSDirectVideoDecoder"
# ── FALLBACK: if Chromium regresses, force ANGLE explicitly: ──
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-gl=angle"
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-angle=opengles"
CHROMIUM_HW_FLAGS
else
    # No rockchip VAAPI driver — GPU compositing only, software video decode.
    cat > "${ROOTFS_MNT}/etc/chromium.d/rk3562-hw-accel" << 'CHROMIUM_SW_FLAGS'
# RK3562 — GPU compositing, software video decode
# (VAAPI driver not found at build time)
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ozone-platform=wayland"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-vulkan"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-gpu-rasterization"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-gpu-compositing"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --password-store=basic"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-accelerated-video-decode"
# RK3562 fallback safety profile: software compositing is slower but avoids
# GPU process crashes seen on some YouTube/Wayland workloads.
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-gpu"
# ── FALLBACK: if Chromium regresses, force ANGLE explicitly: ──
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-gl=angle"
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-angle=opengles"
CHROMIUM_SW_FLAGS
fi

# Phosh resource overlays caused shell UI regressions after fullscreen
# transitions on this image. Keep stock upstream resources for stability.
echo "[*] Disabling Phosh GResource UI overrides..."
rm -f "${ROOTFS_MNT}/etc/profile.d/90-phosh-resource-overrides.sh"
rm -rf "${ROOTFS_MNT}/etc/phosh/resource-overrides/sm/puri/phosh"

# Phosh 0.24 on this panel can require two fingers to pull the top menu in
# landscape when top-panel drag mode is constrained to HANDLE. Patch the two
# hardcoded call sites to FULL so one-finger top-edge drag works consistently.
echo "[*] Patching Phosh top-panel drag mode for landscape swipe..."
PHOSH_BIN="${ROOTFS_MNT}/usr/libexec/phosh"
if [ -f "${PHOSH_BIN}" ]; then
    patch_aarch64_word() {
        local file="$1"
        local offset="$2"
        local expected_hex="$3"
        local patched_hex="$4"
        local label="$5"
        local current_hex payload

        current_hex="$(od -An -tx1 -N4 -j "${offset}" "${file}" | tr -d ' \n')"
        if [ "${current_hex}" = "${patched_hex}" ]; then
            echo "    - ${label}: already patched"
            return 0
        fi
        if [ "${current_hex}" != "${expected_hex}" ]; then
            echo "[!] Warning: ${label} unexpected bytes ${current_hex} (expected ${expected_hex}); skipping patch."
            # Keep build resilient across phosh package updates where opcode
            # bytes can shift; this patch is optional and should not abort.
            return 0
        fi

        payload="$(printf '%s' "${patched_hex}" | sed 's/../\\x&/g')"
        printf '%b' "${payload}" | dd of="${file}" bs=1 seek="${offset}" conv=notrunc status=none
        echo "    - ${label}: patched"
        return 0
    }

    patch_aarch64_word "${PHOSH_BIN}" "$((0x0a7aa0))" "37008052" "17008052" "top-panel drag mode"
    patch_aarch64_word "${PHOSH_BIN}" "$((0x0b7978))" "21008052" "01008052" "osk drag mode"
    unset -f patch_aarch64_word
else
    echo "[!] Warning: ${PHOSH_BIN} not found; drag-mode patch skipped."
fi

# 8. Setting hostname and fstab
echo "[*] Setting hostname and fstab..."
echo "rk3562-debian" > "${ROOTFS_MNT}/etc/hostname"

# Record the requested build profile inside the rootfs for post-flash checks.
cat > "${ROOTFS_MNT}/etc/rkdebian-build-profile" << PROFILE_EOF
BUILD_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RKDEBIAN_UI_SESSION=${RKDEBIAN_UI_SESSION}
RKDEBIAN_DISPLAY_SERVER=${RKDEBIAN_DISPLAY_SERVER}
RKDEBIAN_GPU_STACK=${RKDEBIAN_GPU_STACK}
RKDEBIAN_CPU_GOVERNOR=${RKDEBIAN_CPU_GOVERNOR}
RKDEBIAN_FORCE_CLEAN_ROOTFS=${RKDEBIAN_FORCE_CLEAN_ROOTFS:-0}
PROFILE_EOF

cat > "${ROOTFS_MNT}/etc/fstab" << 'FSTAB'
# <file system>  <mount point>  <type>  <options>        <dump>  <pass>
PARTUUID=c0ffee11-2233-4455-6677-8899aabbccdd  /  ext4  defaults,noatime  0  1
FSTAB

# 9. Configure display manager autologin
echo "[*] Configuring display manager autologin (${RKDEBIAN_UI_SESSION})..."
rm -rf "${ROOTFS_MNT}/etc/sddm.conf.d"
mkdir -p "${ROOTFS_MNT}/etc/lightdm"
# Reused rootfs trees can retain a text-mode default target from prior
# experiments or recovery boots. Force graphical boot so LightDM is started.
ln -sf /lib/systemd/system/graphical.target "${ROOTFS_MNT}/etc/systemd/system/default.target"
# Drop stale gaming-session services from reused rootfs trees; they can keep
# waking up in the background even on desktop-oriented images.
rm -f "${ROOTFS_MNT}/etc/systemd/system/emulationstation.service" \
      "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/emulationstation.service" \
      "${ROOTFS_MNT}/usr/local/bin/rk-start-emulationstation.sh"

# Drop stale per-user overrides from previous experiments that can force a
# mismatched session backend and cause black-screen/login-loop behavior.
rm -f "${ROOTFS_MNT}/home/chaos/.config/environment.d/90-plasma-x11.conf" \
      "${ROOTFS_MNT}/home/chaos/.config/environment.d/91-plasma-shell.conf" \
      "${ROOTFS_MNT}/home/chaos/.config/plasma-org.kde.plasma.phoneshell-appletsrc" \
      "${ROOTFS_MNT}/home/chaos/.config/plasma-org.kde.plasma.desktop-appletsrc" \
      "${ROOTFS_MNT}/home/chaos/.config/plasmashellrc"
rm -rf "${ROOTFS_MNT}/home/chaos/.cache/lomiri" \
       "${ROOTFS_MNT}/home/chaos/.config/lomiri" \
       "${ROOTFS_MNT}/home/chaos/.local/share/lomiri"

# Remove stale KDE LightDM defaults that can override autologin-session.
rm -f "${ROOTFS_MNT}/usr/share/lightdm/lightdm.conf.d/40-kde-plasma-kf5.conf"

# Phosh uses LightDM with autologin into the Wayland session.
cat > "${ROOTFS_MNT}/etc/lightdm/lightdm.conf" << 'LIGHTDM_CONF'
[LightDM]
minimum-vt=1

[Seat:*]
type=local
user-session=phosh
autologin-user=chaos
autologin-session=phosh
session-wrapper=/etc/X11/Xsession

[XDMCPServer]

[VNCServer]
LIGHTDM_CONF
mkdir -p "${ROOTFS_MNT}/etc/X11" "${ROOTFS_MNT}/etc/systemd/system"
printf '%s\n' '/usr/sbin/lightdm' > "${ROOTFS_MNT}/etc/X11/default-display-manager"
ln -sfn /lib/systemd/system/lightdm.service "${ROOTFS_MNT}/etc/systemd/system/display-manager.service"
# Avoid a tty1 text login flicker between boot logo and GUI.
ln -sfn /dev/null "${ROOTFS_MNT}/etc/systemd/system/getty@tty1.service"

# Plasma Discover can fail to launch on this Wayland + Mali stack when Qt's
# default GL path cannot initialize EGL. Provide a software-rendered wrapper
# and override the desktop entry to keep app store access functional.
mkdir -p "${ROOTFS_MNT}/usr/local/bin" "${ROOTFS_MNT}/usr/local/share/applications"
cat > "${ROOTFS_MNT}/usr/local/bin/plasma-discover-safe" << 'PLASMA_DISCOVER_SAFE'
#!/bin/sh
set -eu
export QSG_RHI_BACKEND="${QSG_RHI_BACKEND:-software}"
export QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-software}"
export QT_OPENGL="${QT_OPENGL:-software}"
exec /usr/bin/plasma-discover "$@"
PLASMA_DISCOVER_SAFE
chmod +x "${ROOTFS_MNT}/usr/local/bin/plasma-discover-safe"
if [ -f "${ROOTFS_MNT}/usr/share/applications/org.kde.discover.desktop" ]; then
    cp -f "${ROOTFS_MNT}/usr/share/applications/org.kde.discover.desktop" \
        "${ROOTFS_MNT}/usr/local/share/applications/org.kde.discover.desktop"
    sed -i 's|^Exec=plasma-discover %F$|Exec=/usr/local/bin/plasma-discover-safe %F|' \
        "${ROOTFS_MNT}/usr/local/share/applications/org.kde.discover.desktop"
    sed -i 's|^Exec=plasma-discover --mode update$|Exec=/usr/local/bin/plasma-discover-safe --mode update|' \
        "${ROOTFS_MNT}/usr/local/share/applications/org.kde.discover.desktop"
fi

# Stale user-unit symlinks from old sway-focused rootfs trees can trigger
# waybar restart loops and tank UI responsiveness.
rm -f "${ROOTFS_MNT}/etc/systemd/user/graphical-session.target.wants/waybar.service"

# Remove stale Maliit overrides from reused rootfs trees.
rm -f "${ROOTFS_MNT}/etc/environment.d/90-rkdebian-inputmethod.conf" \
      "${ROOTFS_MNT}/etc/profile.d/90-rkdebian-maliit.sh" \
      "${ROOTFS_MNT}/home/chaos/.config/autostart/maliit-server.desktop"

# Install Phosh auto-rotation helper (raw accelerometer axis polling).
# This mirrors the on-device fix:
# - rotates from /sys axis_data when SensorProxy reports "undefined"
# - honors Phosh top-bar rotation lock toggle
# - uses landscape mapping tuned for this tablet panel orientation
mkdir -p "${ROOTFS_MNT}/home/chaos/.local/bin" "${ROOTFS_MNT}/home/chaos/.config/autostart"
cat > "${ROOTFS_MNT}/home/chaos/.local/bin/phosh-autorotate.sh" << 'PHOSH_AUTOROTATE'
#!/usr/bin/env bash
set -euo pipefail

OUTPUT_NAME="${OUTPUT_NAME:-DSI-1}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
LOG_FILE="$RUNTIME_DIR/phosh-autorotate.log"
STATE_FILE="$RUNTIME_DIR/phosh-autorotate.state"
PRELOCK_FILE="$RUNTIME_DIR/phosh-autorotate.prelock"
AXIS_FILE="${AXIS_FILE:-/sys/devices/virtual/input/input2/axis_data}"
# Ignore near-flat/noisy readings.
AXIS_MIN="${AXIS_MIN:-260}"
DOMINANCE_MARGIN="${DOMINANCE_MARGIN:-180}"
STABLE_POLLS="${STABLE_POLLS:-3}"
POLL_INTERVAL="${POLL_INTERVAL:-0.25}"
LOCKSCREEN_POLL_DIV="${LOCKSCREEN_POLL_DIV:-4}"
# X-axis sign mapping for landscape; tuned for this panel.
X_POS_TRANSFORM="${X_POS_TRANSFORM:-90}"
X_NEG_TRANSFORM="${X_NEG_TRANSFORM:-270}"
STARTUP_SETTLE_SEC="${STARTUP_SETTLE_SEC:-2}"
LANDSCAPE_PRIME_ON_STARTUP="${LANDSCAPE_PRIME_ON_STARTUP:-1}"
LANDSCAPE_PRIME_DELAY="${LANDSCAPE_PRIME_DELAY:-0.20}"
RESYNC_POLLS="${RESYNC_POLLS:-20}"
FORCE_LANDSCAPE_ON_STARTUP="${FORCE_LANDSCAPE_ON_STARTUP:-1}"
FORCE_LANDSCAPE_DELAY="${FORCE_LANDSCAPE_DELAY:-1.5}"
FORCE_LANDSCAPE_FALLBACK="${FORCE_LANDSCAPE_FALLBACK:-$X_NEG_TRANSFORM}"
# Prefer Phosh's DisplayConfig API so shell components relayout in sync
# during rotation. If it glitches, we fail over to wlr-randr and retry.
DISPLAYCONFIG_ENABLED="${DISPLAYCONFIG_ENABLED:-1}"
DISPLAYCONFIG_DEST="${DISPLAYCONFIG_DEST:-sm.puri.Phosh.Portal}"
DISPLAYCONFIG_PATH="${DISPLAYCONFIG_PATH:-/org/gnome/Mutter/DisplayConfig}"
DISPLAYCONFIG_IFACE="${DISPLAYCONFIG_IFACE:-org.gnome.Mutter.DisplayConfig}"
DISPLAYCONFIG_RETRY_POLLS="${DISPLAYCONFIG_RETRY_POLLS:-24}"
use_displayconfig=0
displayconfig_retry_count=0

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

abs() {
  local v="$1"
  if (( v < 0 )); then
    echo $(( -v ))
  else
    echo "$v"
  fi
}

orientation_locked() {
  local v
  v="$(gsettings get org.gnome.settings-daemon.peripherals.touchscreen orientation-lock 2>/dev/null || echo false)"
  [[ "$v" == "true" ]]
}

lockscreen_active() {
  command -v gdbus >/dev/null 2>&1 || return 1
  local v
  v="$(gdbus call --session \
    --dest org.gnome.ScreenSaver \
    --object-path /org/gnome/ScreenSaver \
    --method org.gnome.ScreenSaver.GetActive 2>/dev/null || true)"
  [[ "$v" == *"true"* ]]
}

can_use_displayconfig() {
  [[ "$DISPLAYCONFIG_ENABLED" != "0" ]] || return 1
  command -v busctl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  busctl --user --json=short call \
    "$DISPLAYCONFIG_DEST" "$DISPLAYCONFIG_PATH" "$DISPLAYCONFIG_IFACE" \
    GetCurrentState >/dev/null 2>&1
}

transform_to_rotation() {
  case "$1" in
    normal|0) echo "0" ;;
    90) echo "1" ;;
    180) echo "2" ;;
    270) echo "3" ;;
    *) return 1 ;;
  esac
}

rotation_to_transform() {
  case "$1" in
    0) echo "normal" ;;
    1) echo "90" ;;
    2) echo "180" ;;
    3) echo "270" ;;
    *) return 1 ;;
  esac
}

displayconfig_state_json() {
  busctl --user --json=short call \
    "$DISPLAYCONFIG_DEST" "$DISPLAYCONFIG_PATH" "$DISPLAYCONFIG_IFACE" \
    GetCurrentState 2>/dev/null
}

current_transform_displayconfig() {
  local state rot
  state="$(displayconfig_state_json)" || return 1
  rot="$(echo "$state" | jq -r '.data[2][0][3] // empty')"
  [[ -n "$rot" ]] || return 1
  rotation_to_transform "$rot"
}

apply_transform_displayconfig() {
  local transform="$1"
  local rotation state serial connector mode x y scale primary

  rotation="$(transform_to_rotation "$transform")" || return 1
  state="$(displayconfig_state_json)" || return 1

  serial="$(echo "$state" | jq -r '.data[0] // empty')"
  connector="$(echo "$state" | jq -r '.data[1][0][0][0] // empty')"
  mode="$(echo "$state" | jq -r '.data[1][0][1] | map(select((.[6]["is-current"].data // false) == true))[0][0] // empty')"
  x="$(echo "$state" | jq -r '.data[2][0][0] // empty')"
  y="$(echo "$state" | jq -r '.data[2][0][1] // empty')"
  scale="$(echo "$state" | jq -r '.data[2][0][2] // empty')"
  primary="$(echo "$state" | jq -r '.data[2][0][4] // empty')"

  [[ -n "$serial" && -n "$connector" && -n "$mode" && -n "$x" && -n "$y" && -n "$scale" && -n "$primary" ]] || return 1

  busctl --user call \
    "$DISPLAYCONFIG_DEST" "$DISPLAYCONFIG_PATH" "$DISPLAYCONFIG_IFACE" \
    ApplyMonitorsConfig "uua(iiduba(ssa{sv}))a{sv}" \
    "$serial" 2 \
    1 "$x" "$y" "$scale" "$rotation" "$primary" \
    1 "$connector" "$mode" 0 \
    0 >/dev/null 2>&1
}

detect_wayland_display() {
  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && wlr-randr >/dev/null 2>&1; then
    return 0
  fi

  local sock
  for sock in "$RUNTIME_DIR"/wayland-*; do
    [[ -S "$sock" ]] || continue
    local candidate
    candidate="$(basename "$sock")"
    if WAYLAND_DISPLAY="$candidate" wlr-randr >/dev/null 2>&1; then
      export WAYLAND_DISPLAY="$candidate"
      return 0
    fi
  done

  return 1
}

current_transform() {
  if (( use_displayconfig )); then
    current_transform_displayconfig || true
    return 0
  fi
  wlr-randr 2>/dev/null | awk '/Transform:/ {print $2; exit}' || true
}

output_enabled() {
  wlr-randr 2>/dev/null | awk -v out="$OUTPUT_NAME" '
    $1 == out { in_output=1; next }
    in_output && /Enabled:/ { print $2; exit }
  ' | grep -q '^yes$'
}

apply_transform() {
  local transform="$1"
  local force="${2:-0}"
  [[ -n "$transform" ]] || return 0

  if [[ "$force" != "1" ]] && orientation_locked; then
    return 0
  fi

  local current
  current="$(current_transform)"
  if [[ -n "$current" && "$current" == "$transform" ]]; then
    printf '%s' "$transform" > "$STATE_FILE"
    return 0
  fi

  local last=""
  if [[ -f "$STATE_FILE" ]]; then
    last="$(cat "$STATE_FILE" 2>/dev/null || true)"
  fi
  if [[ "$force" != "1" && "$last" == "$transform" ]]; then
    return 0
  fi

  # First landscape apply after login can race shell init in wlr-randr mode.
  if (( !use_displayconfig )) && [[ "${LANDSCAPE_PRIME_ON_STARTUP}" != "0" &&
        "$startup_prime_done" == "0" &&
        ( "$transform" == "90" || "$transform" == "270" ) ]]; then
    wlr-randr --output "$OUTPUT_NAME" --transform normal >/dev/null 2>&1 || true
    sleep "$LANDSCAPE_PRIME_DELAY"
    startup_prime_done=1
  fi

  if (( use_displayconfig )); then
    if apply_transform_displayconfig "$transform"; then
      printf '%s' "$transform" > "$STATE_FILE"
      log "applied transform=$transform backend=displayconfig"
      return 0
    fi
    # DisplayConfig state can be transiently invalid on lock/wake;
    # fail over so rotation never gets stuck.
    use_displayconfig=0
    if (( DISPLAYCONFIG_RETRY_POLLS > 0 )); then
      displayconfig_retry_count="$DISPLAYCONFIG_RETRY_POLLS"
    fi
    log "displayconfig apply failed transform=$transform; falling back to wlr-randr"
  fi

  if wlr-randr --output "$OUTPUT_NAME" --transform "$transform" >/dev/null 2>&1; then
    printf '%s' "$transform" > "$STATE_FILE"
    log "applied transform=$transform backend=wlr-randr"
  else
    log "failed transform=$transform output=$OUTPUT_NAME"
  fi
}

choose_transform() {
  local x="$1" y="$2" z="$3"
  local ax ay
  ax="$(abs "$x")"
  ay="$(abs "$y")"

  # Ignore flat/noisy states.
  if (( ax < AXIS_MIN && ay < AXIS_MIN )); then
    echo ""
    return 0
  fi

  if (( ay >= ax )); then
    if (( ay - ax < DOMINANCE_MARGIN )); then
      echo ""
      return 0
    fi
    if (( y >= 0 )); then
      echo "normal"
    else
      echo "180"
    fi
  else
    if (( ax - ay < DOMINANCE_MARGIN )); then
      echo ""
      return 0
    fi
    if (( x >= 0 )); then
      echo "$X_POS_TRANSFORM"
    else
      echo "$X_NEG_TRANSFORM"
    fi
  fi
}

startup_landscape_transform() {
  local line x y z candidate

  line="$(cat "$AXIS_FILE" 2>/dev/null || true)"
  if [[ "$line" =~ x=[[:space:]]*(-?[0-9]+)\;y=[[:space:]]*(-?[0-9]+)\;z=[[:space:]]*(-?[0-9]+) ]]; then
    x="${BASH_REMATCH[1]}"
    y="${BASH_REMATCH[2]}"
    z="${BASH_REMATCH[3]}"
    candidate="$(choose_transform "$x" "$y" "$z")"
    if [[ "$candidate" == "90" || "$candidate" == "270" ]]; then
      echo "$candidate"
      return 0
    fi
  fi

  if [[ "$FORCE_LANDSCAPE_FALLBACK" == "90" || "$FORCE_LANDSCAPE_FALLBACK" == "270" ]]; then
    echo "$FORCE_LANDSCAPE_FALLBACK"
  else
    echo "$X_NEG_TRANSFORM"
  fi
}

for _ in $(seq 1 30); do
  if detect_wayland_display; then
    break
  fi
  sleep 1
done

if ! detect_wayland_display; then
  log "unable to find active Wayland socket"
  exit 1
fi

if [[ ! -r "$AXIS_FILE" ]]; then
  log "axis file not readable: $AXIS_FILE"
  exit 1
fi

if can_use_displayconfig; then
  use_displayconfig=1
  log "rotation backend=displayconfig"
else
  if (( DISPLAYCONFIG_RETRY_POLLS > 0 )); then
    displayconfig_retry_count="$DISPLAYCONFIG_RETRY_POLLS"
  fi
  log "rotation backend=wlr-randr"
fi

# Seed state from compositor so we do not force-rotate on startup.
printf '%s' "$(current_transform)" > "$STATE_FILE" 2>/dev/null || true
cp -f "$STATE_FILE" "$PRELOCK_FILE" 2>/dev/null || true
log "starting raw-axis autorotate output=$OUTPUT_NAME wayland=$WAYLAND_DISPLAY axis=$AXIS_FILE"
if [[ "${STARTUP_SETTLE_SEC}" != "0" ]]; then
  sleep "$STARTUP_SETTLE_SEC"
fi

pending=""
pending_count=0
last_lock_state=""
lockscreen_state="false"
last_lockscreen_state=""
prelock_transform="$(cat "$PRELOCK_FILE" 2>/dev/null || true)"
startup_prime_done=0
loop_count=0

if [[ "${FORCE_LANDSCAPE_ON_STARTUP}" != "0" ]]; then
  startup_target="$(startup_landscape_transform)"
  if [[ "${FORCE_LANDSCAPE_DELAY}" != "0" ]]; then
    sleep "$FORCE_LANDSCAPE_DELAY"
  fi
  if [[ -n "$startup_target" ]]; then
    apply_transform "$startup_target" 1
    prelock_transform="$startup_target"
    printf '%s' "$prelock_transform" > "$PRELOCK_FILE" 2>/dev/null || true
    log "startup force landscape transform=$startup_target"
  fi
fi

while true; do
  loop_count=$((loop_count + 1))

  if (( !use_displayconfig )) && (( DISPLAYCONFIG_RETRY_POLLS > 0 )); then
    if (( displayconfig_retry_count > 0 )); then
      displayconfig_retry_count=$((displayconfig_retry_count - 1))
    fi
    if (( displayconfig_retry_count == 0 )) && can_use_displayconfig; then
      use_displayconfig=1
      log "rotation backend=displayconfig (recovered)"
    fi
  fi

  if (( LOCKSCREEN_POLL_DIV <= 1 )) || (( loop_count % LOCKSCREEN_POLL_DIV == 0 )); then
    if lockscreen_active; then
      lockscreen_state="true"
    else
      lockscreen_state="false"
    fi

    if [[ "$lockscreen_state" != "$last_lockscreen_state" ]]; then
      log "lockscreen-active=$lockscreen_state"
      if [[ "$lockscreen_state" == "true" ]]; then
        prelock_transform="$(cat "$STATE_FILE" 2>/dev/null || true)"
        if [[ -z "$prelock_transform" ]]; then
          prelock_transform="$(current_transform)"
        fi
        if [[ -n "$prelock_transform" ]]; then
          printf '%s' "$prelock_transform" > "$PRELOCK_FILE" 2>/dev/null || true
          log "saved prelock-transform=$prelock_transform"
        fi
      fi
      last_lockscreen_state="$lockscreen_state"
    fi

    if [[ "$lockscreen_state" == "true" ]]; then
      if [[ -z "$prelock_transform" ]]; then
        prelock_transform="$(cat "$PRELOCK_FILE" 2>/dev/null || true)"
      fi
      if [[ -n "$prelock_transform" ]] && output_enabled; then
        apply_transform "$prelock_transform" 1
      fi
    fi
  fi

  if (( RESYNC_POLLS > 0 )) && (( loop_count % RESYNC_POLLS == 0 )) &&
     [[ "$lockscreen_state" != "true" ]]; then
    current="$(current_transform)"
    if [[ -n "$current" ]]; then
      printf '%s' "$current" > "$STATE_FILE" 2>/dev/null || true
    fi
  fi

  lock_state="$(gsettings get org.gnome.settings-daemon.peripherals.touchscreen orientation-lock 2>/dev/null || echo false)"
  if [[ "$lock_state" != "$last_lock_state" ]]; then
    log "orientation-lock=$lock_state"
    last_lock_state="$lock_state"
  fi

  line="$(cat "$AXIS_FILE" 2>/dev/null || true)"
  if [[ "$line" =~ x=[[:space:]]*(-?[0-9]+)\;y=[[:space:]]*(-?[0-9]+)\;z=[[:space:]]*(-?[0-9]+) ]]; then
    x="${BASH_REMATCH[1]}"
    y="${BASH_REMATCH[2]}"
    z="${BASH_REMATCH[3]}"
    candidate="$(choose_transform "$x" "$y" "$z")"

    if [[ -n "$candidate" ]]; then
      if [[ "$candidate" == "$pending" ]]; then
        pending_count=$((pending_count + 1))
      else
        pending="$candidate"
        pending_count=1
      fi

      if (( pending_count >= STABLE_POLLS )); then
        if [[ "$lockscreen_state" != "true" ]]; then
          prelock_transform="$candidate"
          printf '%s' "$prelock_transform" > "$PRELOCK_FILE" 2>/dev/null || true
          apply_transform "$candidate"
        fi
      fi
    else
      pending=""
      pending_count=0
    fi
  fi
  sleep "$POLL_INTERVAL"
done
PHOSH_AUTOROTATE
chmod +x "${ROOTFS_MNT}/home/chaos/.local/bin/phosh-autorotate.sh"

cat > "${ROOTFS_MNT}/home/chaos/.config/autostart/phosh-autorotate.desktop" << 'PHOSH_AUTOROTATE_DESKTOP'
[Desktop Entry]
Type=Application
Version=1.0
Name=Phosh Auto Rotate
Comment=Auto-rotate display based on accelerometer axis data
Exec=/home/chaos/.local/bin/phosh-autorotate.sh
OnlyShowIn=Phosh;
X-GNOME-Autostart-enabled=true
NoDisplay=true
PHOSH_AUTOROTATE_DESKTOP

chroot "${ROOTFS_MNT}" chown chaos:chaos \
    /home/chaos/.local/bin/phosh-autorotate.sh \
    /home/chaos/.config/autostart/phosh-autorotate.desktop || true

# Map physical volume keys (adc-keys) to PipeWire volume changes in Phosh.
cat > "${ROOTFS_MNT}/home/chaos/.local/bin/phosh-volume-keys.sh" << 'PHOSH_VOLUME_KEYS'
#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
LOG_FILE="$RUNTIME_DIR/phosh-volume-keys.log"
LOCK_FILE="$RUNTIME_DIR/phosh-volume-keys.lock"
VOLUME_STEP="${VOLUME_STEP:-5}"
VOLUME_MAX="${VOLUME_MAX:-1.5}"
ADC_RAW_FILE="${ADC_RAW_FILE:-/sys/bus/iio/devices/iio:device0/in_voltage1_raw}"
ADC_PLUS_MAX="${ADC_PLUS_MAX:-120}"
ADC_DOWN_MIN="${ADC_DOWN_MIN:-650}"
ADC_DOWN_MAX="${ADC_DOWN_MAX:-920}"
ADC_POLL_INTERVAL="${ADC_POLL_INTERVAL:-0.05}"
ADC_STABLE_POLLS="${ADC_STABLE_POLLS:-2}"
EVENT_DEV="${EVENT_DEV:-}"

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

find_volume_event() {
  local dev
  if [[ -n "$EVENT_DEV" && -r "$EVENT_DEV" ]]; then
    echo "$EVENT_DEV"
    return 0
  fi

  dev="$(awk '
    /^N: Name="adc-keys"/ { match_name=1; next }
    match_name && /^H: Handlers=/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^event[0-9]+$/) {
          print "/dev/input/" $i
          exit
        }
      }
    }
  ' /proc/bus/input/devices 2>/dev/null || true)"

  if [[ -n "$dev" && -r "$dev" ]]; then
    echo "$dev"
    return 0
  fi

  return 1
}

volume_up() {
  wpctl set-volume -l "$VOLUME_MAX" @DEFAULT_AUDIO_SINK@ "${VOLUME_STEP}%+" >/dev/null 2>&1 || true
  wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 >/dev/null 2>&1 || true
}

volume_down() {
  wpctl set-volume @DEFAULT_AUDIO_SINK@ "${VOLUME_STEP}%-" >/dev/null 2>&1 || true
}

adc_state_for_raw() {
  local raw="$1"
  if (( raw <= ADC_PLUS_MAX )); then
    echo "up"
  elif (( raw >= ADC_DOWN_MIN && raw <= ADC_DOWN_MAX )); then
    echo "down"
  else
    echo "none"
  fi
}

if ! command -v wpctl >/dev/null 2>&1; then
  log "wpctl not found; exiting"
  exit 0
fi

mkdir -p "$RUNTIME_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

for _ in $(seq 1 40); do
  if wpctl status >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

# Prefer direct ADC sampling. On some units, both physical keys are reported as
# KEY_VOLUMEUP by the kernel input layer; ADC ranges still distinguish them.
if [[ -r "$ADC_RAW_FILE" ]]; then
  log "using adc mode raw_file=$ADC_RAW_FILE up<=${ADC_PLUS_MAX} down=${ADC_DOWN_MIN}-${ADC_DOWN_MAX}"
  pending="none"
  pending_count=0
  active="none"

  while true; do
    raw="$(cat "$ADC_RAW_FILE" 2>/dev/null || true)"
    if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
      sleep "$ADC_POLL_INTERVAL"
      continue
    fi

    candidate="$(adc_state_for_raw "$raw")"
    if [[ "$candidate" == "$pending" ]]; then
      pending_count=$((pending_count + 1))
    else
      pending="$candidate"
      pending_count=1
    fi

    if (( pending_count >= ADC_STABLE_POLLS )) && [[ "$candidate" != "$active" ]]; then
      active="$candidate"
      case "$active" in
        up)
          log "adc volume up raw=$raw"
          volume_up
          ;;
        down)
          log "adc volume down raw=$raw"
          volume_down
          ;;
      esac
    fi

    sleep "$ADC_POLL_INTERVAL"
  done
fi

while true; do
  dev="$(find_volume_event || true)"
  if [[ -z "$dev" ]]; then
    log "volume input device not found; retrying"
    sleep 2
    continue
  fi

  log "listening on ${dev}"
  evtest --grab "$dev" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *"KEY_VOLUMEUP), value 1"*|*"KEY_VOLUMEUP), value 2"*|*"KEY_UP), value 1"*|*"KEY_UP), value 2"*)
        log "evtest volume up"
        volume_up
        ;;
      *"KEY_VOLUMEDOWN), value 1"*|*"KEY_VOLUMEDOWN), value 2"*|*"KEY_DOWN), value 1"*|*"KEY_DOWN), value 2"*)
        log "evtest volume down"
        volume_down
        ;;
    esac
  done

  log "evtest stream ended; restarting"
  sleep 1
done
PHOSH_VOLUME_KEYS
chmod +x "${ROOTFS_MNT}/home/chaos/.local/bin/phosh-volume-keys.sh"

cat > "${ROOTFS_MNT}/home/chaos/.config/autostart/phosh-volume-keys.desktop" << 'PHOSH_VOLUME_KEYS_DESKTOP'
[Desktop Entry]
Type=Application
Version=1.0
Name=Phosh Volume Keys
Comment=Map physical volume keys to audio sink volume
Exec=/home/chaos/.local/bin/phosh-volume-keys.sh
OnlyShowIn=Phosh;
X-GNOME-Autostart-enabled=true
NoDisplay=true
PHOSH_VOLUME_KEYS_DESKTOP

mkdir -p "${ROOTFS_MNT}/home/chaos/.config/systemd/user/default.target.wants"
cat > "${ROOTFS_MNT}/home/chaos/.config/systemd/user/phosh-volume-keys.service" << 'PHOSH_VOLUME_KEYS_SERVICE'
[Unit]
Description=Map physical volume keys to audio sink volume
After=graphical-session.target pipewire.service
Wants=graphical-session.target

[Service]
Type=simple
ExecStart=/home/chaos/.local/bin/phosh-volume-keys.sh
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
PHOSH_VOLUME_KEYS_SERVICE
ln -sf ../phosh-volume-keys.service \
    "${ROOTFS_MNT}/home/chaos/.config/systemd/user/default.target.wants/phosh-volume-keys.service"

chroot "${ROOTFS_MNT}" chown chaos:chaos \
    /home/chaos/.local/bin/phosh-volume-keys.sh \
    /home/chaos/.config/autostart/phosh-volume-keys.desktop \
    /home/chaos/.config/systemd/user/phosh-volume-keys.service || true

# Prevent duplicate/competing keyboards when reusing an old rootfs tree.
cat > "${ROOTFS_MNT}/home/chaos/.config/autostart/onboard.desktop" << 'ONBOARD_HIDE'
[Desktop Entry]
Hidden=true
ONBOARD_HIDE
cat > "${ROOTFS_MNT}/home/chaos/.config/autostart/onboard-autostart.desktop" << 'ONBOARD_AUTOSTART_HIDE'
[Desktop Entry]
Hidden=true
ONBOARD_AUTOSTART_HIDE
cat > "${ROOTFS_MNT}/home/chaos/.config/autostart/maliit-keyboard.desktop" << 'MALIIT_KEYBOARD_HIDE'
[Desktop Entry]
Hidden=true
MALIIT_KEYBOARD_HIDE
chroot "${ROOTFS_MNT}" chown chaos:chaos \
    /home/chaos/.config/autostart/onboard.desktop \
    /home/chaos/.config/autostart/onboard-autostart.desktop \
    /home/chaos/.config/autostart/maliit-keyboard.desktop || true

# Trim background autostarts that are unnecessary in the Phosh tablet image.
# These either belong to other desktops (XFCE/GNOME) or are optional daemons
# that cost responsiveness on this tablet.
PHOSH_DISABLE_AUTOSTARTS="
blueman.desktop
geoclue-demo-agent.desktop
kup-daemon.desktop
light-locker.desktop
org.kde.discover.notifier.desktop
org.gnome.Software.desktop
print-applet.desktop
rk-xfce4-panel.desktop
xfce4-notifyd.desktop
xfce4-power-manager.desktop
xfsettingsd.desktop
"

# Remove stale per-user overrides/legacy flashlight tray autostarts from
# earlier builds that used AppIndicator.
rm -f \
    "${ROOTFS_MNT}/home/chaos/.config/autostart/ayatana-indicator-application.desktop" \
    "${ROOTFS_MNT}/home/chaos/.config/autostart/rk-indicator-host.desktop" \
    "${ROOTFS_MNT}/home/chaos/.config/autostart/rk-flashlight-indicator.desktop"

for desktop in ${PHOSH_DISABLE_AUTOSTARTS}; do
cat > "${ROOTFS_MNT}/home/chaos/.config/autostart/${desktop}" << 'AUTOSTART_HIDE'
[Desktop Entry]
Hidden=true
AUTOSTART_HIDE
chroot "${ROOTFS_MNT}" chown chaos:chaos "/home/chaos/.config/autostart/${desktop}" || true
done

# Hide launcher entries that are not useful in the tablet image.
mkdir -p "${ROOTFS_MNT}/home/chaos/.local/share/applications"
PHOSH_HIDE_LAUNCHERS="
vim.desktop
yelp.desktop
org.gnome.Help.desktop
org.gnome.Extensions.desktop
org.gnome.Shell.Extensions.desktop
kdesystemsettings.desktop
systemsettings.desktop
org.kde.systemsettings.desktop
debian-xterm.desktop
debian-uxterm.desktop
xterm.desktop
uxterm.desktop
"

for desktop in ${PHOSH_HIDE_LAUNCHERS}; do
cat > "${ROOTFS_MNT}/home/chaos/.local/share/applications/${desktop}" << 'LAUNCHER_HIDE'
[Desktop Entry]
Hidden=true
LAUNCHER_HIDE
chroot "${ROOTFS_MNT}" chown chaos:chaos "/home/chaos/.local/share/applications/${desktop}" || true
done

# Keep a fallback polkit agent autostart for Phosh sessions.
mkdir -p "${ROOTFS_MNT}/etc/xdg/autostart" "${ROOTFS_MNT}/usr/local/bin"
cat > "${ROOTFS_MNT}/usr/local/bin/rk-polkit-agent-launch.sh" << 'RK_POLKIT_LAUNCH'
#!/bin/sh
set -eu

for agent in \
    /usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1 \
    /usr/libexec/polkit-mate-authentication-agent-1 \
    /usr/bin/lxqt-policykit-agent \
    /usr/lib/aarch64-linux-gnu/libexec/polkit-kde-authentication-agent-1 \
    /usr/lib/x86_64-linux-gnu/libexec/polkit-kde-authentication-agent-1 \
    /usr/libexec/polkit-kde-authentication-agent-1 \
    /usr/lib/polkit-kde-authentication-agent-1
do
    if [ -x "${agent}" ]; then
        exec "${agent}"
    fi
done

exit 0
RK_POLKIT_LAUNCH
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-polkit-agent-launch.sh"

if [ ! -f "${ROOTFS_MNT}/etc/xdg/autostart/polkit-gnome-authentication-agent-1.desktop" ] && \
   [ ! -f "${ROOTFS_MNT}/etc/xdg/autostart/lxqt-policykit-agent.desktop" ] && \
   [ ! -f "${ROOTFS_MNT}/etc/xdg/autostart/polkit-kde-authentication-agent-1.desktop" ]; then
cat > "${ROOTFS_MNT}/etc/xdg/autostart/rk-polkit-agent.desktop" << 'POLKIT'
[Desktop Entry]
Type=Application
Name=PolicyKit Authentication Agent
Exec=/usr/local/bin/rk-polkit-agent-launch.sh
OnlyShowIn=Phosh;GNOME;MATE;LXQt;KDE;
X-GNOME-Autostart-enabled=true
POLKIT
fi

# Remove stale keyboard launcher that points to Maliit binaries.
rm -f "${ROOTFS_MNT}/home/chaos/Desktop/on-screen-keyboard.desktop"

# Ensure user-level config/cache dirs are writable by the session user.
# Some build-time mkdir operations run as root and can otherwise leave these
# directories owned by root, which breaks desktop startup.
mkdir -p "${ROOTFS_MNT}/home/chaos/.local" "${ROOTFS_MNT}/home/chaos/.cache"
chroot "${ROOTFS_MNT}" chown -R chaos:chaos \
    /home/chaos/.config \
    /home/chaos/.local \
    /home/chaos/.cache \
    /home/chaos/Desktop || true

# Expose the RKISP front camera as a PipeWire Video/Source for browser apps.
# The kernel camera nodes are multiplanar V4L2 devices; this bridge publishes a
# webcam-style source named "Front_Camera" in the user PipeWire graph.
echo "[*] Installing PipeWire webcam bridge for front camera..."
mkdir -p "${ROOTFS_MNT}/home/chaos/.local/bin"
cat > "${ROOTFS_MNT}/home/chaos/.local/bin/rkcam-webcam.sh" << 'RKCAM_WEBCAM'
#!/bin/sh
set -eu

# Keep pipeline simple/stable under Chromium capture.
# io-mode=0 avoids DMABUF path; queue prevents stalls under load.
exec gst-launch-1.0 --no-fault -q \
  v4l2src device=/dev/video23 io-mode=0 do-timestamp=true ! \
  video/x-raw,format=UYVY,width=1280,height=720,framerate=30/1 ! \
  queue max-size-buffers=4 leaky=downstream ! \
  pipewiresink mode=provide sync=false \
    stream-properties="props,media.class=Video/Source,media.role=Camera,node.name=rkcam-webcam,node.description=Front_Camera,node.nick=Front_Camera"
RKCAM_WEBCAM
chmod +x "${ROOTFS_MNT}/home/chaos/.local/bin/rkcam-webcam.sh"

mkdir -p "${ROOTFS_MNT}/home/chaos/.config/systemd/user/default.target.wants"
cat > "${ROOTFS_MNT}/home/chaos/.config/systemd/user/rkcam-webcam.service" << 'RKCAM_WEBCAM_UNIT'
[Unit]
Description=RK front camera PipeWire webcam bridge
After=pipewire.service wireplumber.service
Wants=pipewire.service wireplumber.service

[Service]
Type=simple
ExecStart=%h/.local/bin/rkcam-webcam.sh
# Refresh portal camera inventory after source appears (works around race)
ExecStartPost=/bin/sh -c 'sleep 1; systemctl --user restart xdg-desktop-portal.service xdg-desktop-portal-gnome.service || true'
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
RKCAM_WEBCAM_UNIT
ln -sfn /home/chaos/.config/systemd/user/rkcam-webcam.service \
    "${ROOTFS_MNT}/home/chaos/.config/systemd/user/default.target.wants/rkcam-webcam.service"

chroot "${ROOTFS_MNT}" chown -R chaos:chaos \
    /home/chaos/.local/bin/rkcam-webcam.sh \
    /home/chaos/.config/systemd/user/rkcam-webcam.service \
    /home/chaos/.config/systemd/user/default.target.wants/rkcam-webcam.service || true

# Install a launcher-friendly on-device front camera preview tool.
mkdir -p "${ROOTFS_MNT}/home/chaos/.local/share/applications"
cat > "${ROOTFS_MNT}/home/chaos/.local/bin/front-camera-preview.sh" << 'FRONT_CAM_PREVIEW'
#!/bin/sh
set -eu

PATH=/usr/local/bin:/usr/bin:/bin
export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

MEDIA_DEV=""
for dev in /dev/media0 /dev/media1 /dev/media2; do
    [ -e "$dev" ] || continue
    if media-ctl -d "$dev" -p 2>/dev/null | grep -q 'rkisp-isp-subdev'; then
        MEDIA_DEV="$dev"
        break
    fi
done

if [ -z "$MEDIA_DEV" ]; then
    echo "[front-camera-preview] ERROR: rkisp media graph not found"
    exit 1
fi

# Keep webcam bridge from competing for /dev/video23 during preview.
systemctl --user stop rkcam-webcam.service >/dev/null 2>&1 || true
killall gst-launch-1.0 >/dev/null 2>&1 || true

# Force front route + stable front ISP dimensions.
media-ctl -d "$MEDIA_DEV" --links '"rkcif-mipi-lvds":0->"rkisp-isp-subdev":0[0]' >/dev/null 2>&1 || true
media-ctl -d "$MEDIA_DEV" --links '"rkcif-mipi-lvds2":0->"rkisp-isp-subdev":0[1]' >/dev/null 2>&1 || true
media-ctl -d "$MEDIA_DEV" --set-v4l2 '"rkcif-mipi-lvds2":0[fmt:SGRBG10_1X10/2592x1944]' >/dev/null 2>&1 || true
media-ctl -d "$MEDIA_DEV" --set-v4l2 '"rkisp-isp-subdev":0[fmt:SGRBG10_1X10/2592x1944 crop:(0,0)/2592x1944]' >/dev/null 2>&1 || true
media-ctl -d "$MEDIA_DEV" --set-v4l2 '"rkisp-isp-subdev":2[fmt:YUYV8_2X8/2592x1944 crop:(0,0)/2592x1944]' >/dev/null 2>&1 || true

# Keep image visible when no 3A daemon is active.
v4l2-ctl -d /dev/v4l-subdev6 -c test_pattern=0 >/dev/null 2>&1 || true
v4l2-ctl -d /dev/v4l-subdev6 -c exposure=1964 >/dev/null 2>&1 || true
v4l2-ctl -d /dev/v4l-subdev6 -c analogue_gain=1024 >/dev/null 2>&1 || true
v4l2-ctl -d /dev/video23 --set-fmt-video=width=1280,height=720,pixelformat=UYVY >/dev/null 2>&1 || true

# Start ISP AWB gain feeder so the ISP outputs real color (not monochrome).
# Without this, rkisp_v8 defaults to zero AWB gains → U=V=128 (gray output).
AWB_PID=""
if command -v rkisp1-awb >/dev/null 2>&1; then
    rkisp1-awb 512 256 256 640 &
    AWB_PID="$!"
fi

cleanup() {
    [ -n "$AWB_PID" ] && kill "$AWB_PID" 2>/dev/null || true
    systemctl --user restart rkcam-webcam.service >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

gst-launch-1.0 --no-fault \
  v4l2src device=/dev/video23 io-mode=0 do-timestamp=true ! \
  video/x-raw,format=UYVY,width=1280,height=720,framerate=15/1 ! \
  videoconvert ! ximagesink sync=false
FRONT_CAM_PREVIEW
chmod +x "${ROOTFS_MNT}/home/chaos/.local/bin/front-camera-preview.sh"

cat > "${ROOTFS_MNT}/home/chaos/.local/share/applications/front-camera-preview.desktop" << 'FRONT_CAM_DESKTOP'
[Desktop Entry]
Type=Application
Name=Front Camera Preview
Comment=Open a live front camera test window
Exec=/home/chaos/.local/bin/front-camera-preview.sh
Icon=camera-photo
Categories=AudioVideo;Video;
Terminal=false
StartupNotify=true
FRONT_CAM_DESKTOP
rm -f \
    "${ROOTFS_MNT}/home/chaos/.local/share/applications/front-camera-preview-natural.desktop" \
    "${ROOTFS_MNT}/home/chaos/.local/share/applications/front-camera-preview-boosted.desktop"

chroot "${ROOTFS_MNT}" chown -R chaos:chaos \
    /home/chaos/.local/bin/front-camera-preview.sh \
    /home/chaos/.local/share/applications/front-camera-preview.desktop || true

# Install launcher-friendly rear camera preview app.
if [ -f "${ROOT_DIR}/overlay/rkcam-rear-preview.sh" ] && \
   [ -f "${ROOT_DIR}/overlay/rkcam-rear-preview.desktop" ]; then
    echo "[*] Installing rear camera preview app..."
    mkdir -p "${ROOTFS_MNT}/home/chaos/.local/bin" \
             "${ROOTFS_MNT}/home/chaos/.local/share/applications" \
             "${ROOTFS_MNT}/home/chaos/Desktop"

    cp "${ROOT_DIR}/overlay/rkcam-rear-preview.sh" \
       "${ROOTFS_MNT}/home/chaos/.local/bin/rkcam-rear-preview.sh"
    chmod +x "${ROOTFS_MNT}/home/chaos/.local/bin/rkcam-rear-preview.sh"

    cp "${ROOT_DIR}/overlay/rkcam-rear-preview.desktop" \
       "${ROOTFS_MNT}/home/chaos/.local/share/applications/rkcam-rear-preview.desktop"
    cp "${ROOT_DIR}/overlay/rkcam-rear-preview.desktop" \
       "${ROOTFS_MNT}/home/chaos/Desktop/Rear-Camera-Preview.desktop"
    chmod +x "${ROOTFS_MNT}/home/chaos/Desktop/Rear-Camera-Preview.desktop"

    chroot "${ROOTFS_MNT}" chown -R chaos:chaos \
        /home/chaos/.local/bin/rkcam-rear-preview.sh \
        /home/chaos/.local/share/applications/rkcam-rear-preview.desktop \
        /home/chaos/Desktop/Rear-Camera-Preview.desktop || true
fi

# Remove deprecated lantern app leftovers from reused base rootfs images.
rm -f \
    "${ROOTFS_MNT}/home/chaos/.local/bin/rk-lantern.sh" \
    "${ROOTFS_MNT}/home/chaos/.local/bin/rk-lantern-screen.py" \
    "${ROOTFS_MNT}/home/chaos/.local/share/applications/rk-lantern.desktop" \
    "${ROOTFS_MNT}/home/chaos/Desktop/Lantern.desktop"

# Force RK817 into a stable capture profile after PipeWire is ready.
echo "[*] Installing RK817 pro-audio profile helper..."
cat > "${ROOTFS_MNT}/home/chaos/.local/bin/rk-audio-pro.sh" << 'RK_AUDIO_PRO'
#!/bin/sh
set -eu

PATH=/usr/bin:/bin

if ! command -v pactl >/dev/null 2>&1; then
    exit 0
fi

for _ in $(seq 1 40); do
    pactl info >/dev/null 2>&1 || {
        sleep 1
        continue
    }
    if pactl list short cards 2>/dev/null | awk '$2 == "alsa_card.platform-rk817-sound" {found=1} END{exit(found?0:1)}'; then
        break
    fi
    sleep 1
done

pactl set-card-profile alsa_card.platform-rk817-sound pro-audio >/dev/null 2>&1 || \
pactl set-card-profile alsa_card.platform-rk817-sound output:stereo-fallback+input:stereo-fallback >/dev/null 2>&1 || true

SINK="$(pactl list short sinks 2>/dev/null | awk '$2 ~ /^alsa_output\.platform-rk817-sound\.pro-output-0$/ {print $2; exit} $2 ~ /^alsa_output\.platform-rk817-sound\.stereo-fallback$/ {print $2; exit}' || true)"
SRC="$(pactl list short sources 2>/dev/null | awk '$2 ~ /^alsa_input\.platform-rk817-sound\.pro-input-0$/ {print $2; exit} $2 ~ /^alsa_input\.platform-rk817-sound\.stereo-fallback$/ {print $2; exit}' || true)"

if [ -n "${SINK}" ]; then
    pactl set-default-sink "${SINK}" >/dev/null 2>&1 || true
fi
if [ -n "${SRC}" ]; then
    pactl set-default-source "${SRC}" >/dev/null 2>&1 || true
    pactl set-source-mute "${SRC}" 0 >/dev/null 2>&1 || true
fi

exit 0
RK_AUDIO_PRO
chmod +x "${ROOTFS_MNT}/home/chaos/.local/bin/rk-audio-pro.sh"

cat > "${ROOTFS_MNT}/home/chaos/.config/systemd/user/rk-audio-pro.service" << 'RK_AUDIO_PRO_UNIT'
[Unit]
Description=Force pro-audio profile for RK817 card
After=pipewire-pulse.service
Wants=pipewire-pulse.service

[Service]
Type=oneshot
ExecStart=%h/.local/bin/rk-audio-pro.sh
RemainAfterExit=yes

[Install]
WantedBy=default.target
RK_AUDIO_PRO_UNIT
ln -sfn /home/chaos/.config/systemd/user/rk-audio-pro.service \
    "${ROOTFS_MNT}/home/chaos/.config/systemd/user/default.target.wants/rk-audio-pro.service"

chroot "${ROOTFS_MNT}" chown -R chaos:chaos \
    /home/chaos/.local/bin/rk-audio-pro.sh \
    /home/chaos/.config/systemd/user/rk-audio-pro.service \
    /home/chaos/.config/systemd/user/default.target.wants/rk-audio-pro.service || true

echo "[*] Skipping virtual microphone source (prefer hardware mic by default)."
rm -f \
    "${ROOTFS_MNT}/home/chaos/.local/bin/rk-virtual-mic.sh" \
    "${ROOTFS_MNT}/home/chaos/.config/systemd/user/rk-virtual-mic.service" \
    "${ROOTFS_MNT}/home/chaos/.config/systemd/user/default.target.wants/rk-virtual-mic.service"

# Launch browsers with native PipeWire camera support enabled.
# This avoids relying on pw-v4l2, which can hang on some builds.
echo "[*] Installing browser wrappers for PipeWire camera..."
mkdir -p "${ROOTFS_MNT}/home/chaos/.local/bin" \
         "${ROOTFS_MNT}/home/chaos/.local/share/applications"

cat > "${ROOTFS_MNT}/home/chaos/.local/bin/chromium-pwcam" << 'CHROMIUM_PWCAM'
#!/bin/bash
set -euo pipefail

args=()
for arg in "$@"; do
  if [[ "$arg" == "--use-fake-ui-for-media-stream" ]]; then
    continue
  fi
  args+=("$arg")
done

exec chromium \
  --ozone-platform-hint=auto \
  --enable-features=UseOzonePlatform,WebRtcPipeWireCamera \
  "${args[@]}"
CHROMIUM_PWCAM
chmod +x "${ROOTFS_MNT}/home/chaos/.local/bin/chromium-pwcam"

cat > "${ROOTFS_MNT}/home/chaos/.local/bin/firefox-pwcam" << 'FIREFOX_PWCAM'
#!/bin/sh
set -eu
exec env -u MOZ_X11_EGL \
  MOZ_DISABLE_RDD_SANDBOX=1 \
  MOZ_ENABLE_WAYLAND=1 \
  MOZ_WAYLAND_USE_VAAPI=1 \
  MOZ_DRM_DEVICE=/dev/dri/renderD128 \
  LIBVA_DRIVER_NAME=rockchip \
  /usr/lib/firefox-esr/firefox-esr \
  --setpref media.webrtc.capture.allow-pipewire=true \
  --setpref media.webrtc.camera.allow-pipewire=true \
  "$@"
FIREFOX_PWCAM
chmod +x "${ROOTFS_MNT}/home/chaos/.local/bin/firefox-pwcam"

if [ -f "${ROOTFS_MNT}/usr/share/applications/chromium.desktop" ]; then
    cp -f "${ROOTFS_MNT}/usr/share/applications/chromium.desktop" \
          "${ROOTFS_MNT}/home/chaos/.local/share/applications/chromium.desktop"
    sed -i 's|^Exec=.*|Exec=/home/chaos/.local/bin/chromium-pwcam %U|' \
          "${ROOTFS_MNT}/home/chaos/.local/share/applications/chromium.desktop"
fi

if [ -f "${ROOTFS_MNT}/usr/share/applications/firefox-esr.desktop" ]; then
    cp -f "${ROOTFS_MNT}/usr/share/applications/firefox-esr.desktop" \
          "${ROOTFS_MNT}/home/chaos/.local/share/applications/firefox-esr.desktop"
    sed -i 's|^Exec=.*|Exec=/home/chaos/.local/bin/firefox-pwcam %u|' \
          "${ROOTFS_MNT}/home/chaos/.local/share/applications/firefox-esr.desktop"
fi

chroot "${ROOTFS_MNT}" chown -R chaos:chaos \
    /home/chaos/.local/bin/chromium-pwcam \
    /home/chaos/.local/bin/firefox-pwcam \
    /home/chaos/.local/share/applications || true

# Power key behavior is handled by rk-powerkey-longpress service:
# - short press (<3s): suspend on key release
# - long press (>=3s): show standard GNOME session shutdown dialog
# logind handling is disabled to avoid conflicting immediate suspend.
mkdir -p "${ROOTFS_MNT}/etc/systemd/logind.conf.d"
cat > "${ROOTFS_MNT}/etc/systemd/logind.conf.d/power-button.conf" << 'LOGIND'
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
LOGIND

echo "[*] Installing long-press power key handler..."
mkdir -p "${ROOTFS_MNT}/usr/local/sbin"
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-powerkey-longpress.py" << 'RK_POWERKEY_LONGPRESS'
#!/usr/bin/env python3
"""Handle hardware power-key short/long press actions for Phosh."""

import os
import pwd
import subprocess
import sys
import time

from evdev import InputDevice, ecodes, list_devices


LONG_PRESS_SECONDS = float(os.environ.get("RK_POWERKEY_LONGPRESS_SECONDS", "3.0"))
TARGET_USER = os.environ.get("RK_POWERKEY_USER", "chaos")
SCAN_INTERVAL_SECONDS = 2.0
TRIGGER_COOLDOWN_SECONDS = 2.0
MIN_PRESS_SECONDS = float(os.environ.get("RK_POWERKEY_MIN_PRESS_SECONDS", "0.12"))
POST_RESUME_IGNORE_SECONDS = float(
    os.environ.get("RK_POWERKEY_POST_RESUME_IGNORE_SECONDS", "4.0")
)
RESUME_DETECT_GAP_SECONDS = float(
    os.environ.get("RK_POWERKEY_RESUME_DETECT_GAP_SECONDS", "1.0")
)
POST_SUSPEND_IGNORE_SECONDS = float(
    os.environ.get("RK_POWERKEY_POST_SUSPEND_IGNORE_SECONDS", "0.75")
)
RELEASE_SETTLE_SECONDS = float(
    os.environ.get("RK_POWERKEY_RELEASE_SETTLE_SECONDS", "0.20")
)
SUSPEND_COOLDOWN_SECONDS = float(
    os.environ.get("RK_POWERKEY_SUSPEND_COOLDOWN_SECONDS", "2.0")
)
last_device_summary = None


def log(msg):
    print(f"rk-powerkey: {msg}", flush=True)


def monotonic_now():
    return time.monotonic()


def boottime_now():
    clock_boottime = getattr(time, "CLOCK_BOOTTIME", None)
    if clock_boottime is None:
        return monotonic_now()
    try:
        return time.clock_gettime(clock_boottime)
    except OSError:
        return monotonic_now()


def detect_resume(last_monotonic, last_boottime):
    now_monotonic = monotonic_now()
    now_boottime = boottime_now()
    suspend_gap = (now_boottime - last_boottime) - (now_monotonic - last_monotonic)
    resumed = suspend_gap >= RESUME_DETECT_GAP_SECONDS
    return now_monotonic, now_boottime, resumed, suspend_gap


def load_target_user():
    entry = pwd.getpwnam(TARGET_USER)
    uid = entry.pw_uid
    runtime_dir = f"/run/user/{uid}"
    bus = f"unix:path={runtime_dir}/bus"
    return uid, runtime_dir, bus


def list_power_devices():
    global last_device_summary
    preferred = {}
    fallback = {}
    all_devs = []
    for path in list_devices():
        try:
            dev = InputDevice(path)
            all_devs.append(dev)
            caps = dev.capabilities().get(ecodes.EV_KEY, [])
            if ecodes.KEY_POWER not in caps:
                dev.close()
                continue

            name = (dev.name or "").lower()
            if "bt-powerkey" in name:
                dev.close()
                continue

            if (
                "rk805 pwrkey" in name
                or "rk8" in name
                or "pwrkey" in name
                or "gpio-keys" in name
            ):
                preferred[path] = dev
            else:
                fallback[path] = dev
        except OSError:
            continue

    devices = preferred if preferred else fallback
    for dev in all_devs:
        path = dev.path
        if path not in devices:
            try:
                dev.close()
            except OSError:
                pass

    for dev in devices.values():
        try:
            dev.grab()
        except OSError:
            pass

    summary = ", ".join(f"{p}:{d.name}" for p, d in sorted(devices.items()))
    if summary != last_device_summary:
        log(f"watching devices: {summary or 'none'}")
        last_device_summary = summary
    return devices


def has_phosh_session(uid):
    result = subprocess.run(
        ["/usr/bin/pgrep", "-u", str(uid), "-f", "/usr/libexec/phosh"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=2,
        check=False,
    )
    return result.returncode == 0


def trigger_shutdown_dialog(uid, runtime_dir, bus):
    if not os.path.exists(f"{runtime_dir}/bus"):
        return False
    if not has_phosh_session(uid):
        return False

    cmd = [
        "/usr/sbin/runuser",
        "-u",
        TARGET_USER,
        "--",
        "/usr/bin/env",
        f"XDG_RUNTIME_DIR={runtime_dir}",
        f"DBUS_SESSION_BUS_ADDRESS={bus}",
        "/usr/bin/gdbus",
        "call",
        "--session",
        "--dest",
        "org.gnome.SessionManager",
        "--object-path",
        "/org/gnome/SessionManager",
        "--method",
        "org.gnome.SessionManager.Shutdown",
    ]
    result = subprocess.run(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=8,
        check=False,
    )
    return result.returncode == 0


def trigger_suspend():
    subprocess.run(
        ["/usr/bin/systemctl", "suspend"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
        check=False,
    )


def main():
    try:
        uid, runtime_dir, bus = load_target_user()
    except KeyError:
        return 0

    power_down_at = None
    power_down_dev = None
    long_fired = False
    pending_suspend_at = None
    last_trigger = 0.0
    last_suspend = 0.0
    ignore_short_until = 0.0
    last_monotonic = monotonic_now()
    last_boottime = boottime_now()

    while True:
        now, now_boot, resumed, suspend_gap = detect_resume(last_monotonic, last_boottime)
        last_monotonic, last_boottime = now, now_boot
        if resumed:
            ignore_short_until = max(
                ignore_short_until, now + POST_RESUME_IGNORE_SECONDS
            )
            power_down_at = None
            power_down_dev = None
            long_fired = False
            pending_suspend_at = None
            log(
                "resume detected "
                f"(+{suspend_gap:.2f}s); short-press suspend paused for "
                f"{POST_RESUME_IGNORE_SECONDS:.1f}s"
            )

        devices = list_power_devices()
        if not devices:
            time.sleep(SCAN_INTERVAL_SECONDS)
            continue

        try:
            next_rescan = monotonic_now() + SCAN_INTERVAL_SECONDS
            while True:
                now, now_boot, resumed, suspend_gap = detect_resume(
                    last_monotonic, last_boottime
                )
                last_monotonic, last_boottime = now, now_boot
                if resumed:
                    ignore_short_until = max(
                        ignore_short_until, now + POST_RESUME_IGNORE_SECONDS
                    )
                    power_down_at = None
                    power_down_dev = None
                    long_fired = False
                    pending_suspend_at = None
                    log(
                        "resume detected "
                        f"(+{suspend_gap:.2f}s); short-press suspend paused for "
                        f"{POST_RESUME_IGNORE_SECONDS:.1f}s"
                    )

                event_seen = False
                for path, dev in list(devices.items()):
                    try:
                        event = dev.read_one()
                    except OSError:
                        event = None
                    if event is None:
                        continue
                    event_seen = True
                    if event.type != ecodes.EV_KEY or event.code != ecodes.KEY_POWER:
                        continue

                    now = monotonic_now()
                    if event.value == 1:
                        # Ignore duplicate key-down repeats from same device.
                        if power_down_at is None:
                            power_down_at = now
                            power_down_dev = path
                            long_fired = False
                            pending_suspend_at = None
                            log(f"power down from {path}")
                    elif event.value == 0:
                        if power_down_at is not None and (
                            power_down_dev is None or path == power_down_dev
                        ):
                            held = now - power_down_at
                            if long_fired:
                                log(f"power up after long press ({held:.2f}s)")
                            elif held >= MIN_PRESS_SECONDS:
                                if now < ignore_short_until:
                                    remaining = ignore_short_until - now
                                    log(
                                        "short press ignored during resume guard "
                                        f"({remaining:.2f}s left)"
                                    )
                                else:
                                    pending_suspend_at = now + RELEASE_SETTLE_SECONDS
                                    log(
                                        f"power up after short press ({held:.2f}s), "
                                        "suspend pending"
                                    )
                            else:
                                log(f"ignored bounce release ({held:.3f}s)")
                        power_down_at = None
                        power_down_dev = None
                        long_fired = False

                now = monotonic_now()
                if power_down_at is not None and not long_fired:
                    held = now - power_down_at
                    if held >= LONG_PRESS_SECONDS:
                        long_fired = True
                        pending_suspend_at = None
                        if (now - last_trigger) >= TRIGGER_COOLDOWN_SECONDS:
                            ok = trigger_shutdown_dialog(uid, runtime_dir, bus)
                            if ok:
                                last_trigger = now
                                log(f"long press action fired ({held:.2f}s)")
                            else:
                                log("long press detected but shutdown dialog failed")

                if (
                    pending_suspend_at is not None
                    and power_down_at is None
                    and now >= pending_suspend_at
                ):
                    pending_suspend_at = None
                    if (now - last_suspend) >= SUSPEND_COOLDOWN_SECONDS:
                        trigger_suspend()
                        last_suspend = now
                        ignore_short_until = max(
                            ignore_short_until, now + POST_SUSPEND_IGNORE_SECONDS
                        )
                        log("short press action fired (suspend)")
                    else:
                        log("suspend suppressed by cooldown")

                if not event_seen:
                    time.sleep(0.05)

                # Re-scan periodically so we survive input-node churn.
                if (
                    monotonic_now() >= next_rescan
                    and power_down_at is None
                    and pending_suspend_at is None
                ):
                    break
        finally:
            for dev in devices.values():
                try:
                    dev.ungrab()
                except OSError:
                    pass
                try:
                    dev.close()
                except OSError:
                    pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
RK_POWERKEY_LONGPRESS
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-powerkey-longpress.py"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-powerkey-longpress.service" << 'RK_POWERKEY_LONGPRESS_UNIT'
[Unit]
Description=Show shutdown dialog on long power-key press
After=systemd-user-sessions.service
Wants=systemd-user-sessions.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/rk-powerkey-longpress.py
Restart=always
RestartSec=1s

[Install]
WantedBy=multi-user.target
RK_POWERKEY_LONGPRESS_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rk-powerkey-longpress.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/rk-powerkey-longpress.service"

echo "[*] Adding polkit rule for backlight control..."
mkdir -p "${ROOTFS_MNT}/etc/polkit-1/rules.d"
cat > "${ROOTFS_MNT}/etc/polkit-1/rules.d/49-backlight.rules" << 'BACKLIGHT_POLKIT'
polkit.addRule(function(action, subject) {
    var backlightAction =
        action.id == "org.freedesktop.login1.set-backlight";

    if (!backlightAction) {
        return;
    }

    if (subject.isInGroup("video")) {
        return polkit.Result.YES;
    }
});
BACKLIGHT_POLKIT

# Reduce Seekwave Wi-Fi UART spam so text tools (nmtui, shell) remain usable.
echo "[*] Installing skwifi log-level service..."
cat > "${ROOTFS_MNT}/etc/systemd/system/skwifi-loglevel.service" << 'SKWIFI_LOG_UNIT'
[Unit]
Description=Set Seekwave Wi-Fi log level to warn
After=systemd-modules-load.service
Before=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for i in $(seq 1 20); do [ -w /proc/skwifi/log_level ] && echo warn > /proc/skwifi/log_level && exit 0; sleep 1; done; exit 0'

[Install]
WantedBy=multi-user.target
SKWIFI_LOG_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/skwifi-loglevel.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/skwifi-loglevel.service"

# Ensure rfkill soft-blocks are cleared each boot.
echo "[*] Installing rfkill unblock service..."
cat > "${ROOTFS_MNT}/etc/systemd/system/rk-unblock-rfkill.service" << 'RFKILL_UNIT'
[Unit]
Description=Unblock all rfkill devices
DefaultDependencies=no
After=systemd-rfkill.service
Before=NetworkManager.service bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock all

[Install]
WantedBy=multi-user.target
RFKILL_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rk-unblock-rfkill.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/rk-unblock-rfkill.service"

# Recover Bluetooth controller if it fails to appear during boot races.
echo "[*] Installing Bluetooth recovery service..."
mkdir -p "${ROOTFS_MNT}/usr/local/sbin"
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-bluetooth-recover.sh" << 'RK_BT_RECOVER'
#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin
READY_FILE="/run/rk-bt-ready"

controller_ready() {
    bluetoothctl list 2>/dev/null | grep -q '^Controller '
}

# If a previous pass marked ready but controller is gone, retry recovery.
if [ -e "${READY_FILE}" ] && controller_ready; then
    exit 0
fi
rm -f "${READY_FILE}" 2>/dev/null || true

if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock all || true
fi

if command -v modprobe >/dev/null 2>&1; then
    modprobe skwbt >/dev/null 2>&1 || true
fi

for _ in $(seq 1 20); do
    if controller_ready; then
        printf 'power on\nquit\n' | bluetoothctl >/dev/null 2>&1 || true
        touch "${READY_FILE}"
        exit 0
    fi
    sleep 1
done

# Keep boot behavior stable: avoid force-unloading/restarting BT from a
# background helper because that can make the controller disappear mid-boot.
exit 0
RK_BT_RECOVER
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-bluetooth-recover.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-bluetooth-recover.service" << 'RK_BT_RECOVER_UNIT'
[Unit]
Description=Recover Seekwave Bluetooth controller
After=systemd-modules-load.service dbus.service bluetooth.service NetworkManager.service
Wants=bluetooth.service NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-bluetooth-recover.sh

[Install]
WantedBy=multi-user.target
RK_BT_RECOVER_UNIT

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-bluetooth-recover.timer" << 'RK_BT_RECOVER_TIMER'
[Unit]
Description=Retry Seekwave Bluetooth recovery until controller appears

[Timer]
OnBootSec=90s
OnUnitActiveSec=5min
AccuracySec=1s
Unit=rk-bluetooth-recover.service

[Install]
WantedBy=timers.target
RK_BT_RECOVER_TIMER

# Do not auto-enable recovery service/timer by default. They can still be
# started manually for debugging:
#   systemctl start rk-bluetooth-recover.service
mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
mkdir -p "${ROOTFS_MNT}/etc/systemd/system/timers.target.wants"
rm -f "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/rk-bluetooth-recover.service"
rm -f "${ROOTFS_MNT}/etc/systemd/system/timers.target.wants/rk-bluetooth-recover.timer"

# Harden bluetooth.service startup ordering for Seekwave BT.
echo "[*] Installing Bluetooth service override..."
mkdir -p "${ROOTFS_MNT}/etc/systemd/system/bluetooth.service.d"
cat > "${ROOTFS_MNT}/etc/systemd/system/bluetooth.service.d/rk-skwbt.conf" << 'RK_BT_OVERRIDE'
[Unit]
# Drop Debian's default ConditionPathIsDirectory=/sys/class/bluetooth so
# bluetoothd can start and request module bring-up on first boot.
ConditionPathIsDirectory=
After=systemd-modules-load.service rk-unblock-rfkill.service
Wants=rk-unblock-rfkill.service

[Service]
ExecStartPre=/bin/sh -c '/usr/sbin/modprobe skwbt >/dev/null 2>&1 || true; for i in $(seq 1 20); do [ -d /sys/class/bluetooth ] && exit 0; sleep 1; done; exit 0'
ExecStartPre=/bin/sh -c '/usr/sbin/rfkill unblock all >/dev/null 2>&1 || true'
ExecStartPost=/bin/sh -c 'printf "power on\nquit\n" | /usr/bin/bluetoothctl >/dev/null 2>&1 || true'
Restart=on-failure
RestartSec=2
RK_BT_OVERRIDE

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/bluetooth.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/bluetooth.service"

# Screen rotation tray icon — manual rotation selector with optional
# accelerometer auto-rotate.  Replaces the old rk-autorotate.service daemon.
echo "[*] Installing screen-rotation tray applet..."

# udev rule: let the "video" group read/write the accelerometer device so the
# tray app (running as the desktop user) can poll it without root.
cat > "${ROOTFS_MNT}/etc/udev/rules.d/91-accelerometer.rules" << 'ACCEL_UDEV'
KERNEL=="mma8452_daemon", MODE="0660", GROUP="video"
ACCEL_UDEV

mkdir -p "${ROOTFS_MNT}/usr/local/bin"
cat > "${ROOTFS_MNT}/usr/local/bin/rk-screen-rotate.py" << 'RK_SCREEN_ROTATE'
#!/usr/bin/env python3
"""System-tray applet for screen rotation on RK3562 tablet.

Works in X11 and in Wayland sessions that provide swaymsg-compatible output IPC.

Under X11:  uses xrandr for display rotation and xinput for touch mapping.
Under Wayland: uses swaymsg output transforms, maps the touchscreen to the
               active output, and resets stale calibration matrices.
"""

import array
import fcntl
import glob
import json
import os
import re
import subprocess
import threading
import time

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3 as AppIndicator3  # noqa: E402
from gi.repository import GLib, Gtk  # noqa: E402

# ---------------------------------------------------------------------------
# Session detection
# ---------------------------------------------------------------------------
IS_WAYLAND = os.environ.get("XDG_SESSION_TYPE", "") == "wayland"

# ---------------------------------------------------------------------------
# Accelerometer constants
# ---------------------------------------------------------------------------
SENSOR_DEV = "/dev/mma8452_daemon"
GSENSOR_IOCTL_START = 0x6103
GSENSOR_IOCTL_APP_SET_RATE = 0x40026110
GSENSOR_IOCTL_GETDATA = 0x800D6108
POLL_SECONDS = 0.5
THRESHOLD = 6000
STABLE_SAMPLES = 3

# ---------------------------------------------------------------------------
# Rotation helpers
# ---------------------------------------------------------------------------
ORIENTATIONS = ["normal", "left", "right", "inverted"]

LABELS = {
    "normal":   "Normal (Portrait)",
    "left":     "Left (Landscape)",
    "right":    "Right (Landscape)",
    "inverted": "Inverted (Portrait)",
}

# xinput Coordinate Transformation Matrix — X11 only (9 elements)
MATRICES = {
    "normal":   [1,  0, 0,  0,  1, 0, 0, 0, 1],
    "left":     [0, -1, 1,  1,  0, 0, 0, 0, 1],
    "right":    [0,  1, 0, -1,  0, 1, 0, 0, 1],
    "inverted": [-1, 0, 1,  0, -1, 1, 0, 0, 1],
}

# wlr transform names — Wayland only
WL_TRANSFORMS = {
    "normal":   "normal",
    "left":     "270",
    "right":    "90",
    "inverted": "180",
}

ICON_DEFAULT = "video-display"
IDENTITY_TOUCH_MATRIX = "1 0 0 0 1 0"


def _swaysock_path():
    """Best-effort SWAYSOCK lookup for non-interactive contexts."""
    env_sock = os.environ.get("SWAYSOCK", "")
    if env_sock and os.path.exists(env_sock):
        return env_sock
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if runtime:
        socks = sorted(glob.glob(os.path.join(runtime, "sway-ipc.*.sock")))
        if socks:
            return socks[-1]
    return None


def _swaymsg(args):
    """Run swaymsg with explicit socket fallback when needed."""
    cmd = ["swaymsg"]
    sock = _swaysock_path()
    if sock:
        cmd += ["--socket", sock]
    cmd += list(args)
    return subprocess.run(cmd, text=True, capture_output=True)


def _sway_output():
    """Return the name of the first active sway output via swaymsg JSON."""
    res = _swaymsg(["-t", "get_outputs"])
    if res.returncode != 0:
        return None
    try:
        outputs = json.loads(res.stdout)
        for o in outputs:
            if o.get("active"):
                return o["name"]
        if outputs:
            return outputs[0]["name"]
    except Exception:
        pass
    return None


def _x11_connected_output():
    """Return the name of the first connected xrandr output."""
    res = subprocess.run(["xrandr", "--query"], text=True, capture_output=True)
    if res.returncode != 0:
        return None
    outputs = []
    for line in res.stdout.splitlines():
        if " connected" in line and "disconnected" not in line:
            outputs.append(line.split()[0])
    if not outputs:
        return None
    for prefix in ("DSI", "eDP", "LVDS"):
        for out in outputs:
            if out.startswith(prefix):
                return out
    return outputs[0]


def _x11_touchscreen_devices():
    """Return list of xinput device names matching the touchscreen."""
    res = subprocess.run(
        ["xinput", "list", "--name-only"], text=True, capture_output=True
    )
    if res.returncode != 0:
        return []
    devs = []
    for line in res.stdout.splitlines():
        name = line.strip()
        if re.search(r"(gsl3673|touchscreen|touch)", name, re.IGNORECASE):
            devs.append(name)
    return devs


def _sway_touch_identifier():
    """Return the sway input identifier for the first touch device."""
    res = _swaymsg(["-t", "get_inputs"])
    if res.returncode != 0:
        return None
    try:
        for dev in json.loads(res.stdout):
            if dev.get("type") == "touch":
                return dev["identifier"]
    except Exception:
        pass
    return None


def _wayland_current_orientation():
    """Read current active output transform and map it to our orientation key."""
    res = _swaymsg(["-t", "get_outputs"])
    if res.returncode != 0:
        return "normal"
    try:
        outputs = json.loads(res.stdout)
        target = None
        for out in outputs:
            if out.get("active"):
                target = out
                break
        if target is None and outputs:
            target = outputs[0]
        transform = str((target or {}).get("transform", "normal"))
        mapping = {
            "normal": "normal",
            "90": "right",
            "180": "inverted",
            "270": "left",
        }
        return mapping.get(transform, "normal")
    except Exception:
        return "normal"


def apply_orientation(orientation):
    """Rotate display and update touch mapping for the current session type."""
    if IS_WAYLAND:
        output = _sway_output()
        if not output:
            return False
        # Rotate the output
        res = _swaymsg(["output", output, "transform", WL_TRANSFORMS[orientation]])
        if res.returncode != 0:
            return False
        # Keep touch mapped to the active output and clear stale calibration.
        touch_id = _sway_touch_identifier()
        if touch_id:
            _swaymsg(["--", "input", touch_id, "map_to_output", output])
            _swaymsg(["--", "input", touch_id, "calibration_matrix",
                      IDENTITY_TOUCH_MATRIX])
        return True
    else:
        # xrandr --rotate (including --rotate normal) crashes the X server with
        # the Mali BSP glamor driver.  Do not call xrandr at all under X11.
        # Only update the xinput touch matrix for "normal" to keep calibration.
        if orientation != "normal":
            return False
        matrix = MATRICES["normal"]
        for dev in _x11_touchscreen_devices():
            subprocess.run(
                ["xinput", "set-prop", dev,
                 "Coordinate Transformation Matrix",
                 *(str(v) for v in matrix)],
                capture_output=True,
            )
        return True


# ---------------------------------------------------------------------------
# Accelerometer reader (runs in a background thread)
# ---------------------------------------------------------------------------
class AccelReader:
    """Polls the MMA8452 accelerometer and calls *callback(orientation)*
    on the GLib main-loop when a stable orientation change is detected."""

    def __init__(self, callback):
        self._callback = callback
        self._stop = threading.Event()
        self._thread = None

    def start(self):
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
            self._thread = None

    @property
    def running(self):
        return self._thread is not None and self._thread.is_alive()

    @staticmethod
    def _open_sensor():
        fd = os.open(SENSOR_DEV, os.O_RDWR | os.O_CLOEXEC)
        fcntl.ioctl(fd, GSENSOR_IOCTL_START, 0)
        rate = array.array("h", [20])
        fcntl.ioctl(fd, GSENSOR_IOCTL_APP_SET_RATE, rate, True)
        return fd

    @staticmethod
    def _read_axis(fd):
        vals = array.array("i", [0, 0, 0])
        fcntl.ioctl(fd, GSENSOR_IOCTL_GETDATA, vals, True)
        return vals[0], vals[1], vals[2]

    @staticmethod
    def _detect(x, y):
        ax, ay = abs(x), abs(y)
        if ax < THRESHOLD and ay < THRESHOLD:
            return None
        if ax >= ay:
            return "left" if x > 0 else "right"
        return "inverted" if y > 0 else "normal"

    def _run(self):
        fd = None
        pending = None
        pending_count = 0
        while not self._stop.is_set():
            try:
                if fd is None:
                    if not os.path.exists(SENSOR_DEV):
                        time.sleep(1.0)
                        continue
                    fd = self._open_sensor()
                x, y, _ = self._read_axis(fd)
                orient = self._detect(x, y)
                if orient is not None:
                    if orient == pending:
                        pending_count += 1
                    else:
                        pending = orient
                        pending_count = 1
                    if pending_count >= STABLE_SAMPLES:
                        GLib.idle_add(self._callback, orient)
                        pending_count = 0
                time.sleep(POLL_SECONDS)
            except Exception:
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    fd = None
                time.sleep(1.0)
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Tray applet
# ---------------------------------------------------------------------------
class RotateTray:
    def __init__(self):
        self._current = _wayland_current_orientation() if IS_WAYLAND else "normal"
        self._auto = False
        self._accel = AccelReader(self._on_accel_orient)

        self._indicator = AppIndicator3.Indicator.new(
            "rk-screen-rotate",
            ICON_DEFAULT,
            AppIndicator3.IndicatorCategory.HARDWARE,
        )
        self._indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        self._indicator.set_title("Screen Rotation")
        self._build_menu()

    def _build_menu(self):
        menu = Gtk.Menu()

        self._auto_item = Gtk.CheckMenuItem(label="Auto-rotate")
        self._auto_item.set_active(self._auto)
        if not IS_WAYLAND:
            self._auto_item.set_sensitive(False)
        self._auto_item.connect("toggled", self._on_auto_toggled)
        menu.append(self._auto_item)

        menu.append(Gtk.SeparatorMenuItem())

        if not IS_WAYLAND:
            note = Gtk.MenuItem(
                label="⚠ Rotation requires swaymsg-compatible Wayland"
            )
            note.set_sensitive(False)
            menu.append(note)

        self._orient_items = {}
        group = None
        for orient in ORIENTATIONS:
            if group is None:
                item = Gtk.RadioMenuItem(label=LABELS[orient])
                group = item
            else:
                item = Gtk.RadioMenuItem.new_with_label_from_widget(
                    group, LABELS[orient]
                )
            if orient == self._current:
                item.set_active(True)
            # Disable non-normal options on X11 — xrandr --rotate crashes Xorg
            if not IS_WAYLAND and orient != "normal":
                item.set_sensitive(False)
            item.connect("toggled", self._on_orient_toggled, orient)
            self._orient_items[orient] = item
            menu.append(item)

        menu.append(Gtk.SeparatorMenuItem())

        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", self._on_quit)
        menu.append(quit_item)

        menu.show_all()
        self._indicator.set_menu(menu)

    def _on_orient_toggled(self, item, orient):
        if not item.get_active():
            return
        if orient == self._current:
            return
        if self._auto:
            self._auto = False
            self._accel.stop()
            self._auto_item.set_active(False)
        self._apply(orient)

    def _on_auto_toggled(self, item):
        self._auto = item.get_active()
        if self._auto:
            self._accel.start()
        else:
            self._accel.stop()

    def _on_accel_orient(self, orient):
        if not self._auto:
            return
        if orient == self._current:
            return
        self._apply(orient)
        item = self._orient_items.get(orient)
        if item and not item.get_active():
            item.set_active(True)

    def _on_quit(self, _item):
        self._accel.stop()
        Gtk.main_quit()

    def _apply(self, orient):
        if apply_orientation(orient):
            self._current = orient

    def run(self):
        Gtk.main()


def main():
    auto_start = os.path.exists(SENSOR_DEV) and os.access(
        SENSOR_DEV, os.R_OK | os.W_OK
    )
    app = RotateTray()
    if IS_WAYLAND:
        # Ensure touch mapping starts in sync with the current transform.
        apply_orientation(app._current)
    if auto_start:
        app._auto = True
        app._auto_item.set_active(True)
        app._accel.start()
    app.run()


if __name__ == "__main__":
    main()
RK_SCREEN_ROTATE
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-screen-rotate.py"

# Use native Phosh torch quick-setting support (Phosh 0.24+).
# The kernel DT exposes the rear flashlight as an LED-class device (:flash),
# so Phosh discovers it automatically in the top menu.
# Remove legacy AppIndicator helpers from reused rootfs trees.
rm -f \
    "${ROOTFS_MNT}/usr/local/bin/rk-indicator-host.sh" \
    "${ROOTFS_MNT}/usr/local/bin/rk-flashlight-indicator.py" \
    "${ROOTFS_MNT}/etc/xdg/autostart/rk-indicator-host.desktop" \
    "${ROOTFS_MNT}/etc/xdg/autostart/rk-flashlight-indicator.desktop"

echo "[*] Installing flashlight control helper..."
mkdir -p "${ROOTFS_MNT}/usr/local/sbin"

cat > "${ROOTFS_MNT}/usr/local/sbin/rk-flashlightctl" << 'RK_FLASHLIGHT_CTL'
#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin

LED_NAME="${FLASHLIGHT_LED_NAME:-camera:flash}"
LED_DIR="/sys/class/leds/${LED_NAME}"

GPIO="${FLASHLIGHT_GPIO:-114}"
GPIO_DIR="/sys/class/gpio/gpio${GPIO}"
EXPORT="/sys/class/gpio/export"
UNEXPORT="/sys/class/gpio/unexport"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "rk-flashlightctl must run as root" >&2
        exit 1
    fi
}

ensure_exported() {
    if [ -d "${GPIO_DIR}" ]; then
        return 0
    fi
    echo "${GPIO}" > "${EXPORT}"
    sleep 0.02
}

led_present() {
    [ -d "${LED_DIR}" ] && [ -r "${LED_DIR}/max_brightness" ] && [ -r "${LED_DIR}/brightness" ]
}

led_writable() {
    led_present && [ -w "${LED_DIR}/brightness" ]
}

led_max() {
    cat "${LED_DIR}/max_brightness" 2>/dev/null || echo 1
}

led_set_raw() {
    echo "${1}" > "${LED_DIR}/brightness"
}

gpio_set_on() {
    ensure_exported
    echo out > "${GPIO_DIR}/direction"
    echo 1 > "${GPIO_DIR}/value"
}

gpio_set_off() {
    if [ -d "${GPIO_DIR}" ]; then
        echo out > "${GPIO_DIR}/direction" 2>/dev/null || true
        echo 0 > "${GPIO_DIR}/value" 2>/dev/null || true
        echo "${GPIO}" > "${UNEXPORT}" 2>/dev/null || true
    fi
}

set_percent() {
    p="${1}"
    case "${p}" in
        ''|*[!0-9]*)
            echo "percent must be an integer 0..100" >&2
            exit 2
            ;;
    esac
    if [ "${p}" -gt 100 ]; then
        p=100
    fi

    if led_writable; then
        max="$(led_max)"
        v=$(( p * max / 100 ))
        if [ "${p}" -gt 0 ] && [ "${v}" -eq 0 ]; then
            v=1
        fi
        led_set_raw "${v}"
    else
        if [ "${p}" -eq 0 ]; then
            gpio_set_off
        else
            gpio_set_on
        fi
    fi
}

set_off() {
    set_percent 0
}

status_now() {
    if led_present; then
        v="$(cat "${LED_DIR}/brightness" 2>/dev/null || echo 0)"
        if [ "${v}" -gt 0 ]; then
            echo "on"
            return 0
        fi
        echo "off"
        return 0
    fi

    if [ -d "${GPIO_DIR}" ] && [ -r "${GPIO_DIR}/value" ]; then
        v="$(cat "${GPIO_DIR}/value" 2>/dev/null || echo 0)"
        if [ "${v}" = "1" ]; then
            echo "on"
            return 0
        fi
    fi
    echo "off"
}

main() {
    case "${1:-}" in
        on)
            require_root
            set_percent 100
            ;;
        off)
            require_root
            set_off
            ;;
        toggle)
            require_root
            if [ "$(status_now)" = "on" ]; then
                set_off
            else
                set_percent 100
            fi
            ;;
        set)
            require_root
            set_percent "${2:-}"
            ;;
        status)
            status_now
            ;;
        *)
            echo "Usage: $0 {on|off|toggle|set <0-100>|status}" >&2
            exit 2
            ;;
    esac
}

main "${@:-}"
RK_FLASHLIGHT_CTL
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-flashlightctl"

# Wayland desktop env vars for Phosh sessions.
cat > "${ROOTFS_MNT}/etc/profile.d/rk-wayland.sh" << 'RK_WAYLAND_PROFILE'
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    export GDK_BACKEND=wayland,x11
    export QT_QPA_PLATFORM="wayland;xcb"
    export SDL_VIDEODRIVER=wayland
    export MOZ_ENABLE_WAYLAND=1
    export MOZ_DISABLE_RDD_SANDBOX=1
    export MOZ_WAYLAND_USE_VAAPI=1
    export MOZ_DRM_DEVICE=/dev/dri/renderD128
    export LIBVA_DRIVER_NAME=rockchip
    export ELECTRON_OZONE_PLATFORM_HINT=auto
fi
RK_WAYLAND_PROFILE

# Initialize ALSA controls at boot so speaker/mic paths are sane on RK817.
echo "[*] Installing ALSA init service..."
mkdir -p "${ROOTFS_MNT}/usr/local/sbin"
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-audio-init.sh" << 'RK_AUDIO_INIT'
#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin

/usr/sbin/alsactl init || true

for c in /proc/asound/card*; do
    [ -d "$c" ] || continue
    i=${c##*/card}
    /usr/bin/amixer -q -c "$i" sset Speaker unmute >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset Speaker 100% >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset Headphone unmute >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset Headphone 100% >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset Master unmute >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset Master 100% >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset PCM unmute >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset PCM 100% >/dev/null 2>&1 || true
done

rk_card=""
if [ -r /proc/asound/cards ]; then
    rk_card="$(awk '/rk817|rockchip-rk817/ {print $1; exit}' /proc/asound/cards | tr -d ' ' || true)"
fi

if [ -n "$rk_card" ]; then
    # Program codec route twice to survive late resume register resets.
    pass=0
    while [ "$pass" -lt 2 ]; do
        /usr/bin/amixer -q -c "$rk_card" cset name='Resume Path' ON >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" cset name='Playback Path' OFF >/dev/null 2>&1 || true
        sleep 1
        for path in SPK SPK_HP HP RCV; do
            /usr/bin/amixer -q -c "$rk_card" cset name='Playback Path' "$path" >/dev/null 2>&1 && break
        done
        /usr/bin/amixer -q -c "$rk_card" cset name='DAC Playback Volume' 230,230 >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" sset 'DAC' 230,230 >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" sset 'HP Output Gain' 3 >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" cset name='Speaker Switch' on >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" sset 'spk switch' on >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" sset 'hp switch' off >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" cset name='Capture MIC Path' 'Main Mic' >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" sset 'Main Mic' on >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" sset 'Headset Mic' off >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" sset 'ADC' 255,255 >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" sset 'ADC PGA Gain' 15,15 >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" sset 'MIC Boost Gain' 3,3 >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" cset name='Capture Volume' 192 >/dev/null 2>&1 || true
        /usr/bin/amixer -q -c "$rk_card" cset name='PCM' 192 >/dev/null 2>&1 || true
        pass=$((pass + 1))
    done
fi

/usr/sbin/alsactl store >/dev/null 2>&1 || true

exit 0
RK_AUDIO_INIT
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-audio-init.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-alsa-init.service" << 'ALSA_INIT_UNIT'
[Unit]
Description=Initialize ALSA controls
After=systemd-modules-load.service sound.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-audio-init.sh

[Install]
WantedBy=multi-user.target
ALSA_INIT_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rk-alsa-init.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/rk-alsa-init.service"

# Restore PulseAudio sink/source routing at desktop login. Some boots expose
# HDMI/null outputs first and leave analog output muted.
echo "[*] Installing desktop audio recovery helper..."
mkdir -p "${ROOTFS_MNT}/usr/local/bin"
cat > "${ROOTFS_MNT}/usr/local/bin/rk-audio-session-fix.sh" << 'RK_AUDIO_SESSION'
#!/bin/sh
set -eu

PATH=/usr/bin:/bin

if ! command -v pactl >/dev/null 2>&1; then
    exit 0
fi

for _ in $(seq 1 20); do
    pactl info >/dev/null 2>&1 && break
    sleep 1
done

sink="$(pactl list short sinks 2>/dev/null | awk '$2 ~ /^alsa_output\.platform-rk817-sound\./ && $2 !~ /\.monitor$/ {print $2; exit} $2 ~ /analog-stereo/ && $2 !~ /\.monitor$/ {print $2; exit}' || true)"
if [ -n "${sink}" ]; then
    pactl set-default-sink "${sink}" >/dev/null 2>&1 || true
    pactl set-sink-mute "${sink}" 0 >/dev/null 2>&1 || true
fi

source="$(pactl list short sources 2>/dev/null | awk '$2 ~ /^alsa_input\.platform-rk817-sound\./ {print $2; exit} $2 ~ /analog-stereo/ && $2 !~ /\.monitor$/ && $2 != "virtual-mic" {print $2; exit}' || true)"
if [ -n "${source}" ]; then
    pactl set-default-source "${source}" >/dev/null 2>&1 || true
    pactl set-source-mute "${source}" 0 >/dev/null 2>&1 || true
fi

if [ -x /usr/local/bin/rk-audio-volume-state.sh ]; then
    /usr/local/bin/rk-audio-volume-state.sh restore >/dev/null 2>&1 || true
fi

exit 0
RK_AUDIO_SESSION
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-audio-session-fix.sh"

echo "[*] Installing persistent audio volume helper..."
cat > "${ROOTFS_MNT}/usr/local/bin/rk-audio-volume-state.sh" << 'RK_AUDIO_VOLUME_STATE'
#!/bin/sh
set -eu

PATH=/usr/bin:/bin

STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rk-audio"
STATE_FILE="${STATE_DIR}/volume.env"

get_sink() {
    pactl list short sinks 2>/dev/null | awk '
        $2 ~ /^alsa_output\.platform-rk817-sound\./ && $2 !~ /\.monitor$/ {print $2; exit}
        $2 ~ /analog-stereo/ && $2 !~ /\.monitor$/ {print $2; exit}
    ' || true
}

wait_ready() {
    i=0
    while [ "${i}" -lt 20 ]; do
        if pactl info >/dev/null 2>&1; then
            sink="$(get_sink)"
            [ -n "${sink}" ] && return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

save_state() {
    sink="${1:-$(get_sink)}"
    [ -n "${sink}" ] || return 0

    volume="$(pactl get-sink-volume "${sink}" 2>/dev/null | awk '/Volume:/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+%$/) {print $i; exit}}' || true)"
    mute="$(pactl get-sink-mute "${sink}" 2>/dev/null | awk '{print $2; exit}' || true)"
    [ -n "${volume}" ] || return 0

    mkdir -p "${STATE_DIR}"
    tmp="${STATE_FILE}.tmp"
    {
        printf 'VOLUME=%s\n' "${volume}"
        printf 'MUTE=%s\n' "${mute:-no}"
    } > "${tmp}"
    mv "${tmp}" "${STATE_FILE}"
}

restore_state() {
    [ -r "${STATE_FILE}" ] || return 0
    # shellcheck source=/dev/null
    . "${STATE_FILE}" || return 0

    sink="$(get_sink)"
    [ -n "${sink}" ] || return 0

    case "${VOLUME:-}" in
        ''|*[!0-9%]*)
            ;;
        *)
            pactl set-sink-volume "${sink}" "${VOLUME}" >/dev/null 2>&1 || true
            ;;
    esac

    case "${MUTE:-}" in
        yes|no)
            pactl set-sink-mute "${sink}" "${MUTE}" >/dev/null 2>&1 || true
            ;;
    esac
}

monitor_state() {
    while :; do
        pactl subscribe 2>/dev/null | while IFS= read -r line; do
            case "${line}" in
                *" on sink "*|*" on server "*|*" on card "*)
                    save_state
                    ;;
            esac
        done
        sleep 1
    done
}

mode="${1:-monitor}"
case "${mode}" in
    restore)
        wait_ready >/dev/null 2>&1 || exit 0
        restore_state
        ;;
    save)
        wait_ready >/dev/null 2>&1 || exit 0
        save_state
        ;;
    monitor)
        wait_ready >/dev/null 2>&1 || exit 0
        restore_state
        save_state
        monitor_state
        ;;
    *)
        echo "Usage: $0 {restore|save|monitor}" >&2
        exit 2
        ;;
esac

exit 0
RK_AUDIO_VOLUME_STATE
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-audio-volume-state.sh"

mkdir -p "${ROOTFS_MNT}/etc/systemd/user" \
         "${ROOTFS_MNT}/etc/systemd/user/default.target.wants"
cat > "${ROOTFS_MNT}/etc/systemd/user/rk-audio-volume-state.service" << 'RK_AUDIO_VOLUME_STATE_UNIT'
[Unit]
Description=Persist audio sink volume and mute state
After=pipewire-pulse.service
Wants=pipewire-pulse.service

[Service]
Type=simple
ExecStart=/usr/local/bin/rk-audio-volume-state.sh monitor
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
RK_AUDIO_VOLUME_STATE_UNIT
ln -sf /etc/systemd/user/rk-audio-volume-state.service \
    "${ROOTFS_MNT}/etc/systemd/user/default.target.wants/rk-audio-volume-state.service"

cat > "${ROOTFS_MNT}/etc/xdg/autostart/rk-audio-session-fix.desktop" << 'RK_AUDIO_SESSION_DESKTOP'
[Desktop Entry]
Type=Application
Name=RK Audio Session Fix
Exec=/usr/local/bin/rk-audio-session-fix.sh
OnlyShowIn=Phosh;GNOME;
X-GNOME-Autostart-enabled=true
NoDisplay=true
RK_AUDIO_SESSION_DESKTOP

# Recover audio stack after suspend/resume. Some RK817 + PipeWire sessions
# come back without a valid default sink until card/profile routing is reapplied.
echo "[*] Installing suspend/resume audio recovery hook..."
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-audio-resume.sh" << 'RK_AUDIO_RESUME'
#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin

TARGET_USER="${RK_AUDIO_USER:-chaos}"
LOG_FILE="/var/log/rk-audio-resume.log"
CARD_NAME="alsa_card.platform-rk817-sound"

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "${LOG_FILE}"
}

run_as_user() {
    uid="$(id -u "${TARGET_USER}" 2>/dev/null || true)"
    [ -n "${uid}" ] || return 1

    runtime_dir="/run/user/${uid}"
    [ -S "${runtime_dir}/bus" ] || return 1

    dbus_addr="unix:path=${runtime_dir}/bus"
    /usr/sbin/runuser -u "${TARGET_USER}" -- /usr/bin/env \
        XDG_RUNTIME_DIR="${runtime_dir}" \
        DBUS_SESSION_BUS_ADDRESS="${dbus_addr}" \
        "$@"
}

wait_pactl() {
    i=0
    while [ "${i}" -lt 12 ]; do
        if run_as_user /usr/bin/pactl info >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

wait_card() {
    i=0
    while [ "${i}" -lt 12 ]; do
        if run_as_user /bin/sh -c \
            "pactl list short cards 2>/dev/null | awk '\$2 == \"${CARD_NAME}\" {found=1} END{exit(found?0:1)}'" \
            >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

enforce_hw_mixer() {
    rk_card=""
    if [ -r /proc/asound/cards ]; then
        rk_card="$(awk '/rk817|rockchip-rk817/ {print $1; exit}' /proc/asound/cards | tr -d ' ' || true)"
    fi
    [ -n "${rk_card}" ] || return 0

    /usr/bin/amixer -q -c "${rk_card}" cset name='Resume Path' ON >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "${rk_card}" cset name='Playback Path' OFF >/dev/null 2>&1 || true
    sleep 1
    for path in SPK SPK_HP HP RCV; do
        /usr/bin/amixer -q -c "${rk_card}" cset name='Playback Path' "${path}" >/dev/null 2>&1 && break
    done
    /usr/bin/amixer -q -c "${rk_card}" cset name='Speaker Switch' on >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "${rk_card}" cset name='DAC Playback Volume' 230,230 >/dev/null 2>&1 || true
}

get_sink() {
    run_as_user /bin/sh -c \
        "pactl list short sinks 2>/dev/null | awk '\
            \$2 ~ /^alsa_output\\.platform-rk817-sound\\./ && \$2 !~ /\\.monitor\$/ {print \$2; exit}
            \$2 ~ /analog-stereo/ && \$2 !~ /\\.monitor\$/ {print \$2; exit}
        '" 2>/dev/null || true
}

get_source() {
    run_as_user /bin/sh -c \
        "pactl list short sources 2>/dev/null | awk '\
            \$2 ~ /^alsa_input\\.platform-rk817-sound\\./ {print \$2; exit}
            \$2 ~ /analog-stereo/ && \$2 !~ /\\.monitor\$/ && \$2 != \"virtual-mic\" {print \$2; exit}
        '" 2>/dev/null || true
}

restart_user_audio() {
    log "fallback: restarting user audio services"
    run_as_user /usr/bin/systemctl --user restart \
        pipewire.service wireplumber.service pipewire-pulse.service >/dev/null 2>&1 || true
    sleep 1
}

move_streams_to_sink() {
    sink="$1"
    [ -n "${sink}" ] || return 0

    for input_id in $(run_as_user /bin/sh -c \
        "pactl list short sink-inputs 2>/dev/null | awk '{print \$1}'" \
        2>/dev/null || true); do
        run_as_user /usr/bin/pactl move-sink-input "${input_id}" "${sink}" >/dev/null 2>&1 || true
    done
}

queue_delayed_user_fix() {
    # Re-apply default sink/source shortly after wake when session graph settles.
    run_as_user /bin/sh -c \
        '(sleep 2; /usr/local/bin/rk-audio-session-fix.sh >/dev/null 2>&1 || true; \
          sleep 3; /usr/local/bin/rk-audio-session-fix.sh >/dev/null 2>&1 || true) &' \
        >/dev/null 2>&1 || true
}

apply_routing() {
    run_as_user /usr/bin/pactl set-card-profile \
        "${CARD_NAME}" pro-audio >/dev/null 2>&1 || \
    run_as_user /usr/bin/pactl set-card-profile \
        "${CARD_NAME}" output:stereo-fallback+input:stereo-fallback >/dev/null 2>&1 || true

    sink="$(get_sink)"
    if [ -n "${sink}" ]; then
        run_as_user /usr/bin/pactl set-default-sink "${sink}" >/dev/null 2>&1 || true
        run_as_user /usr/bin/pactl set-sink-mute "${sink}" 0 >/dev/null 2>&1 || true
        run_as_user /usr/local/bin/rk-audio-volume-state.sh restore >/dev/null 2>&1 || true
        move_streams_to_sink "${sink}"
    fi

    source="$(get_source)"
    if [ -n "${source}" ]; then
        run_as_user /usr/bin/pactl set-default-source "${source}" >/dev/null 2>&1 || true
        run_as_user /usr/bin/pactl set-source-mute "${source}" 0 >/dev/null 2>&1 || true
    fi

    log "resume audio recovery applied sink=${sink:-none} source=${source:-none}"
}

fix_user_audio() {
    enforce_hw_mixer || true

    if ! wait_pactl; then
        log "pactl not ready"
        return 1
    fi

    if ! wait_card; then
        log "card not visible, attempting fallback restart"
        restart_user_audio
        wait_pactl || true
        wait_card || true
    fi

    apply_routing
    queue_delayed_user_fix

    if [ -z "$(get_sink)" ]; then
        log "sink still missing, final fallback restart"
        restart_user_audio
        wait_pactl || true
        apply_routing
    fi

    enforce_hw_mixer || true
    return 0
}

if [ "${1:-}" = "worker" ]; then
    log "resume worker action=${2:-unknown} begin"
    /usr/local/sbin/rk-audio-init.sh >/dev/null 2>&1 || true
    sleep 1
    fix_user_audio || true
    log "resume worker action=${2:-unknown} done"
    exit 0
fi

if [ "${1:-}" != "post" ]; then
    exit 0
fi

case "${2:-}" in
    suspend|hibernate|hybrid-sleep|suspend-then-hibernate|"")
        action="${2:-unknown}"
        log "resume hook action=${action} queued"
        /usr/bin/systemd-run \
            --unit="rk-audio-resume-worker-$(date +%s)" \
            --collect \
            --quiet \
            --no-block \
            --service-type=oneshot \
            /usr/local/sbin/rk-audio-resume.sh worker "${action}" >/dev/null 2>&1 || {
                log "resume hook enqueue failed, running inline"
                /usr/local/sbin/rk-audio-init.sh >/dev/null 2>&1 || true
                sleep 1
                fix_user_audio || true
            }
        ;;
esac

exit 0
RK_AUDIO_RESUME
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-audio-resume.sh"

mkdir -p "${ROOTFS_MNT}/lib/systemd/system-sleep"
cat > "${ROOTFS_MNT}/lib/systemd/system-sleep/rk-audio-resume" << 'RK_AUDIO_RESUME_SLEEP'
#!/bin/sh
exec /usr/local/sbin/rk-audio-resume.sh "$@"
RK_AUDIO_RESUME_SLEEP
chmod +x "${ROOTFS_MNT}/lib/systemd/system-sleep/rk-audio-resume"

# 10. USB role manager service (OTG host + charging)
if [ -f "${ROOT_DIR}/overlay/usb-mode-switch.sh" ] && [ -f "${ROOT_DIR}/overlay/usb-role-manager.service" ]; then
    echo "[*] Installing USB role manager service..."
    cp "${ROOT_DIR}/overlay/usb-mode-switch.sh" "${ROOTFS_MNT}/usr/local/bin/usb-mode-switch.sh"
    chmod +x "${ROOTFS_MNT}/usr/local/bin/usb-mode-switch.sh"
    cp "${ROOT_DIR}/overlay/usb-role-manager.service" "${ROOTFS_MNT}/etc/systemd/system/usb-role-manager.service"
    # Clean up deprecated services that caused one-sided behavior.
    chroot "${ROOTFS_MNT}" systemctl disable usb-force-host.service usb-otg-host.service >/dev/null 2>&1 || true
    chroot "${ROOTFS_MNT}" systemctl enable usb-role-manager.service
fi

# 10b. Front camera ISP setup service (s5k5e8 → rkisp → /dev/video23)
if [ -f "${ROOT_DIR}/overlay/camera-isp-setup.sh" ] && \
   [ -f "${ROOT_DIR}/overlay/camera-isp-setup.service" ]; then
    echo "[*] Installing front camera ISP setup service..."

    # Cross-compile config_isp helper if source is present and cross-compiler available
    if [ -f "${ROOT_DIR}/tools/config_isp.c" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        aarch64-linux-gnu-gcc -O2 -o "${ROOTFS_MNT}/usr/local/bin/config_isp" \
            "${ROOT_DIR}/tools/config_isp.c" && \
            echo "[*] config_isp compiled for arm64" || \
            echo "[!] Warning: config_isp compilation failed — ISP crop reset won't run"
    fi

    cp "${ROOT_DIR}/overlay/camera-isp-setup.sh" "${ROOTFS_MNT}/usr/local/bin/camera-isp-setup.sh"
    chmod +x "${ROOTFS_MNT}/usr/local/bin/camera-isp-setup.sh"
    cp "${ROOT_DIR}/overlay/camera-isp-setup.service" "${ROOTFS_MNT}/etc/systemd/system/camera-isp-setup.service"
    chroot "${ROOTFS_MNT}" systemctl enable camera-isp-setup.service
fi

if [ -f "${ROOT_DIR}/tools/setup_isp_rear.sh" ]; then
    echo "[*] Installing rear camera ISP setup helper..."
    cp "${ROOT_DIR}/tools/setup_isp_rear.sh" "${ROOTFS_MNT}/usr/local/bin/setup_isp_rear.sh"
    chmod +x "${ROOTFS_MNT}/usr/local/bin/setup_isp_rear.sh"
fi

# 10b-awb. ISP AWB gain feeder (rkisp1-awb) — provides color to s5k5e8 front camera
# The rkisp_v8 vendor ISP defaults to zero AWB gains (monochrome output).
# rkisp1-awb feeds R/Gr/Gb/B gain params per-frame via /dev/video28.
if [ -f "${ROOT_DIR}/tools/rkisp1_awb.c" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    echo "[*] Compiling rkisp1-awb AWB gain feeder..."
    aarch64-linux-gnu-gcc -O2 -o "${ROOTFS_MNT}/usr/local/bin/rkisp1-awb" \
        "${ROOT_DIR}/tools/rkisp1_awb.c" && \
        echo "[*] rkisp1-awb compiled for arm64" || \
        echo "[!] Warning: rkisp1-awb compilation failed — front camera will show monochrome"
fi

# Install rkisp1-awb as a user service that runs alongside rkcam-webcam
mkdir -p "${ROOTFS_MNT}/home/chaos/.config/systemd/user/rkcam-webcam.service.wants"
cat > "${ROOTFS_MNT}/home/chaos/.config/systemd/user/rkisp1-awb.service" << 'RKISP1_AWB_UNIT'
[Unit]
Description=RkISP1 AWB gain feeder for front camera (s5k5e8)
After=rkcam-webcam.service
BindsTo=rkcam-webcam.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 0.5
ExecStart=/usr/local/bin/rkisp1-awb 512 256 256 640
Restart=on-failure
RestartSec=1

[Install]
WantedBy=rkcam-webcam.service
RKISP1_AWB_UNIT
ln -sfn /home/chaos/.config/systemd/user/rkisp1-awb.service \
    "${ROOTFS_MNT}/home/chaos/.config/systemd/user/rkcam-webcam.service.wants/rkisp1-awb.service"
chroot "${ROOTFS_MNT}" chown -R chaos:chaos \
    /home/chaos/.config/systemd/user/rkisp1-awb.service \
    /home/chaos/.config/systemd/user/rkcam-webcam.service.wants || true

# 10b. (removed) rk817-hard-poweroff userspace service was removed.
# The kernel's rk817_battery_shutdown() now saves dsoc/capacity before
# pm_power_off_prepare runs, and rk817_shutdown_prepare() writes DEV_OFF
# directly via i2c_smbus.  A userspace service running before systemd-poweroff
# would kill the PMIC before the kernel can save battery state.

# 10c. Power tuning service (WiFi power-save + Phosh power-profile CPU mapping)
echo "[*] Installing power tuning service..."
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-power-tune.sh" << RK_POWER_TUNE
#!/bin/sh
# RK3562 tablet power tuning — runs once at boot after network is up.
CPU_GOVERNOR="${RKDEBIAN_CPU_GOVERNOR}"

# Enable WiFi power save if interface exists
for iface in wlan0 wlan1; do
    if ip link show "\$iface" > /dev/null 2>&1; then
        iw dev "\$iface" set power_save on 2>/dev/null || true
    fi
done

# Keep a responsive baseline governor until the profile-sync daemon below
# applies the current power profile mapping.
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -f "\$policy/scaling_governor" ] || continue
    echo "\$CPU_GOVERNOR" > "\$policy/scaling_governor" 2>/dev/null || true
done
RK_POWER_TUNE
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-power-tune.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-power-tune.service" << 'RK_POWER_TUNE_UNIT'
[Unit]
Description=RK3562 power tuning (responsive CPU governor, WiFi power-save)
After=local-fs.target
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-power-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
RK_POWER_TUNE_UNIT
chroot "${ROOTFS_MNT}" systemctl enable rk-power-tune.service

# Map power-profiles-daemon profiles to cpufreq behavior so Phosh's
# "Balanced" and "Power Saver" switch directly controls CPU policy.
cat > "${ROOTFS_MNT}/etc/default/rk-power-profile-map" << RK_POWER_PROFILE_MAP
# Profile to governor mapping for rk-power-profile-sync.sh
# Valid governors: performance, schedutil, ondemand, powersave, conservative, userspace
RK_POWER_BALANCED_GOVERNOR="${RKDEBIAN_CPU_GOVERNOR}"
RK_POWER_SAVER_GOVERNOR="powersave"
RK_POWER_PERFORMANCE_GOVERNOR="performance"

# Max frequency cap (percentage of cpuinfo_max_freq) per profile.
RK_POWER_BALANCED_MAX_PCT="100"
RK_POWER_SAVER_MAX_PCT="65"
RK_POWER_PERFORMANCE_MAX_PCT="100"

# Polling interval (seconds) for profile changes.
RK_POWER_PROFILE_POLL_SEC="2"
RK_POWER_PROFILE_MAP

cat > "${ROOTFS_MNT}/usr/local/sbin/rk-power-profile-sync.sh" << 'RK_POWER_PROFILE_SYNC'
#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin
CONF_FILE="/etc/default/rk-power-profile-map"

RK_POWER_BALANCED_GOVERNOR="performance"
RK_POWER_SAVER_GOVERNOR="powersave"
RK_POWER_PERFORMANCE_GOVERNOR="performance"
RK_POWER_BALANCED_MAX_PCT="100"
RK_POWER_SAVER_MAX_PCT="65"
RK_POWER_PERFORMANCE_MAX_PCT="100"
RK_POWER_PROFILE_POLL_SEC="2"

if [ -r "${CONF_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${CONF_FILE}"
fi

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

sanitize_pct() {
    val="$1"
    def="$2"
    if is_uint "${val}" && [ "${val}" -ge 1 ] && [ "${val}" -le 100 ] 2>/dev/null; then
        echo "${val}"
    else
        echo "${def}"
    fi
}

sanitize_poll() {
    val="$1"
    if is_uint "${val}" && [ "${val}" -ge 1 ] 2>/dev/null; then
        echo "${val}"
    else
        echo "2"
    fi
}

RK_POWER_BALANCED_MAX_PCT="$(sanitize_pct "${RK_POWER_BALANCED_MAX_PCT}" "100")"
RK_POWER_SAVER_MAX_PCT="$(sanitize_pct "${RK_POWER_SAVER_MAX_PCT}" "65")"
RK_POWER_PERFORMANCE_MAX_PCT="$(sanitize_pct "${RK_POWER_PERFORMANCE_MAX_PCT}" "100")"
RK_POWER_PROFILE_POLL_SEC="$(sanitize_poll "${RK_POWER_PROFILE_POLL_SEC}")"

log_msg() {
    logger -t rk-power-profile-sync "$*" 2>/dev/null || true
}

is_governor_available() {
    gov="$1"
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -r "${policy}/scaling_available_governors" ] || continue
        tr ' ' '\n' < "${policy}/scaling_available_governors" | grep -qx "${gov}" && return 0
    done
    return 1
}

choose_governor() {
    requested="$1"
    fallback_list="$2"
    if is_governor_available "${requested}"; then
        echo "${requested}"
        return 0
    fi
    for gov in ${fallback_list}; do
        if is_governor_available "${gov}"; then
            echo "${gov}"
            return 0
        fi
    done
    echo ""
    return 1
}

read_profile() {
    if ! command -v powerprofilesctl >/dev/null 2>&1; then
        echo "balanced"
        return 0
    fi

    profile="$(powerprofilesctl get 2>/dev/null || true)"
    case "${profile}" in
        power-saver|balanced|performance) echo "${profile}" ;;
        *) echo "balanced" ;;
    esac
}

apply_profile() {
    profile="$1"
    case "${profile}" in
        power-saver)
            requested_governor="${RK_POWER_SAVER_GOVERNOR}"
            max_pct="${RK_POWER_SAVER_MAX_PCT}"
            fallback="powersave conservative schedutil ondemand interactive performance userspace"
            ;;
        performance)
            requested_governor="${RK_POWER_PERFORMANCE_GOVERNOR}"
            max_pct="${RK_POWER_PERFORMANCE_MAX_PCT}"
            fallback="performance schedutil ondemand interactive conservative powersave userspace"
            ;;
        *)
            requested_governor="${RK_POWER_BALANCED_GOVERNOR}"
            max_pct="${RK_POWER_BALANCED_MAX_PCT}"
            fallback="performance schedutil ondemand interactive conservative powersave userspace"
            ;;
    esac

    chosen_governor="$(choose_governor "${requested_governor}" "${fallback}" || true)"

    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "${policy}" ] || continue

        if [ -n "${chosen_governor}" ] && [ -w "${policy}/scaling_governor" ]; then
            echo "${chosen_governor}" > "${policy}/scaling_governor" 2>/dev/null || true
        fi

        if [ -r "${policy}/cpuinfo_max_freq" ] && [ -r "${policy}/cpuinfo_min_freq" ] && [ -w "${policy}/scaling_max_freq" ]; then
            max_freq="$(tr -cd '0-9' < "${policy}/cpuinfo_max_freq")"
            min_freq="$(tr -cd '0-9' < "${policy}/cpuinfo_min_freq")"
            if is_uint "${max_freq}" && [ "${max_freq}" -gt 0 ] 2>/dev/null; then
                cap_freq=$((max_freq * max_pct / 100))
                if is_uint "${min_freq}" && [ "${cap_freq}" -lt "${min_freq}" ] 2>/dev/null; then
                    cap_freq="${min_freq}"
                fi

                if [ -w "${policy}/scaling_min_freq" ]; then
                    cur_min="$(tr -cd '0-9' < "${policy}/scaling_min_freq" 2>/dev/null || true)"
                    if is_uint "${cur_min}" && [ "${cur_min}" -gt "${cap_freq}" ] 2>/dev/null; then
                        echo "${cap_freq}" > "${policy}/scaling_min_freq" 2>/dev/null || true
                    fi
                fi

                echo "${cap_freq}" > "${policy}/scaling_max_freq" 2>/dev/null || true
            fi
        fi
    done

    log_msg "profile=${profile} requested_gov=${requested_governor} applied_gov=${chosen_governor:-none} max_pct=${max_pct}"
}

last_profile=""
while :; do
    profile="$(read_profile)"
    if [ "${profile}" != "${last_profile}" ]; then
        apply_profile "${profile}"
        last_profile="${profile}"
    fi
    sleep "${RK_POWER_PROFILE_POLL_SEC}"
done
RK_POWER_PROFILE_SYNC
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-power-profile-sync.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-power-profile-sync.service" << 'RK_POWER_PROFILE_SYNC_UNIT'
[Unit]
Description=Sync CPU governor/frequency caps with Power Profiles mode
After=power-profiles-daemon.service rk-power-tune.service
Wants=power-profiles-daemon.service rk-power-tune.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/rk-power-profile-sync.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
RK_POWER_PROFILE_SYNC_UNIT
chroot "${ROOTFS_MNT}" systemctl enable rk-power-profile-sync.service

# 10d. RK817 battery gauge recovery (fixes occasional false 0% after cold-off).
echo "[*] Installing RK817 battery gauge recovery service..."
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-battery-gauge-fix.sh" << 'RK_BAT_GAUGE_FIX'
#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin
LOG_FILE="/var/log/rk-battery-gauge-fix.log"
CAP_FILE="/sys/class/power_supply/battery/capacity"
VOLT_FILE="/sys/class/power_supply/battery/voltage_now"
LOW_SOC_FIX_MAX=35
HIGH_VOLTAGE_FIX_UV=4000000

say() {
    echo "[$(date -Iseconds)] rk-battery-gauge-fix: $*" >> "${LOG_FILE}"
}

read_int_file() {
    file="$1"
    if [ -f "${file}" ]; then
        tr -cd '0-9' < "${file}"
    fi
}

is_power_online() {
    for p in /sys/class/power_supply/ac/online /sys/class/power_supply/usb/online; do
        [ -f "${p}" ] || continue
        val="$(read_int_file "${p}")"
        [ -n "${val}" ] && [ "${val}" -eq 1 ] && return 0
    done
    return 1
}

mkdir -p /var/log
touch "${LOG_FILE}"

if ! command -v i2cset >/dev/null 2>&1; then
    say "i2cset not found, skipping"
    exit 0
fi

resolve_i2c_bus() {
    for dev in /sys/bus/i2c/devices/*-0020; do
        [ -e "${dev}" ] || continue
        bus="${dev##*/}"
        bus="${bus%-0020}"
        [ -n "${bus}" ] && {
            echo "${bus}"
            return 0
        }
    done

    [ -e /dev/i2c-0 ] && {
        echo "0"
        return 0
    }

    return 1
}

if [ ! -f "${CAP_FILE}" ] || [ ! -f "${VOLT_FILE}" ]; then
    say "battery sysfs missing, skipping"
    exit 0
fi

cap="$(read_int_file "${CAP_FILE}")"
volt="$(read_int_file "${VOLT_FILE}")"
[ -z "${cap}" ] && cap=0
[ -z "${volt}" ] && volt=0

# Trigger only on suspicious states:
# - battery reports 0% with non-empty voltage / charger online
# - battery reports very low SOC, but pack voltage is clearly high
fix_reason=""
if [ "${cap}" -eq 0 ]; then
    if [ "${volt}" -lt 3600000 ] && ! is_power_online; then
        say "capacity=0 and low voltage (${volt}uV) with no charger: likely real empty, no fix"
        exit 0
    fi
    fix_reason="capacity=0 voltage_now=${volt}uV"
elif [ "${cap}" -le "${LOW_SOC_FIX_MAX}" ] && [ "${volt}" -ge "${HIGH_VOLTAGE_FIX_UV}" ]; then
    fix_reason="capacity=${cap}% but voltage_now=${volt}uV suggests stuck-low gauge"
else
    say "capacity=${cap}% voltage_now=${volt}uV: no fix needed"
    exit 0
fi

i2c_bus="$(resolve_i2c_bus || true)"
if [ -z "${i2c_bus}" ]; then
    say "could not locate RK817 i2c bus, skipping"
    exit 0
fi

say "detected possible stuck gauge (${fix_reason}), applying fix on i2c-${i2c_bus}"
if command -v i2cget >/dev/null 2>&1; then
    gg_sts_raw="$(i2cget -f -y "${i2c_bus}" 0x20 0x57 2>/dev/null || true)"
    case "${gg_sts_raw}" in
        0x[0-9a-fA-F]|0x[0-9a-fA-F][0-9a-fA-F])
            gg_sts_new_dec=$((gg_sts_raw | 0x10))
            gg_sts_new_hex="$(printf '0x%02x' "${gg_sts_new_dec}")"
            i2cset -f -y "${i2c_bus}" 0x20 0x57 "${gg_sts_new_hex}" >/dev/null 2>&1 || {
                say "i2cset command failed"
                exit 0
            }
            say "GG_STS ${gg_sts_raw} -> ${gg_sts_new_hex} (set BAT_CON)"
            ;;
        *)
            say "GG_STS read failed (${gg_sts_raw}), falling back to legacy write 0x51"
            i2cset -f -y "${i2c_bus}" 0x20 0x57 0x51 >/dev/null 2>&1 || {
                say "i2cset command failed"
                exit 0
            }
            ;;
    esac
else
    say "i2cget not found, using legacy write 0x51"
    i2cset -f -y "${i2c_bus}" 0x20 0x57 0x51 >/dev/null 2>&1 || {
        say "i2cset command failed"
        exit 0
    }
fi

# Nudge power_supply userspace updates.
udevadm trigger --subsystem-match=power_supply --action=change >/dev/null 2>&1 || true
sleep 1

new_cap="$(read_int_file "${CAP_FILE}")"
[ -z "${new_cap}" ] && new_cap=0
if [ "${new_cap}" -eq 0 ]; then
    say "after fix: capacity still 0% (BAT_CON will take effect on next reboot)"
else
    say "after fix: capacity=${new_cap}%"
fi

exit 0
RK_BAT_GAUGE_FIX
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-battery-gauge-fix.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-battery-gauge-fix.service" << 'RK_BAT_GAUGE_FIX_UNIT'
[Unit]
Description=RK817 battery gauge recovery at boot
DefaultDependencies=no
After=local-fs.target systemd-udev-settle.service
Wants=systemd-udev-settle.service
Before=display-manager.service
ConditionPathExists=/dev/i2c-0
ConditionPathExists=/sys/class/power_supply/battery/capacity

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-battery-gauge-fix.sh
TimeoutSec=10

[Install]
WantedBy=multi-user.target
RK_BAT_GAUGE_FIX_UNIT
chroot "${ROOTFS_MNT}" systemctl enable rk-battery-gauge-fix.service

# 10e. RK817 hard power-off hook (avoid poweroff->reboot bounce).
echo "[*] Installing RK817 DEV_OFF shutdown hook..."
mkdir -p "${ROOTFS_MNT}/lib/systemd/system-shutdown"
cat > "${ROOTFS_MNT}/lib/systemd/system-shutdown/rk817-devoff" << 'RK817_DEVOFF_HOOK'
#!/bin/sh
set -eu

mode="${1:-}"
case "${mode}" in
    poweroff|halt) ;;
    *) exit 0 ;;
esac

PATH=/usr/sbin:/usr/bin:/sbin:/bin
I2C_BUS=0
PMIC_ADDR=0x20
SYS_CFG3_REG=0xf4

log() {
    echo "rk817-devoff: $*" > /dev/kmsg 2>/dev/null || true
}

if command -v i2cget >/dev/null 2>&1 && command -v i2cset >/dev/null 2>&1; then
    raw="$(i2cget -y -f "${I2C_BUS}" "${PMIC_ADDR}" "${SYS_CFG3_REG}" b 2>/dev/null || true)"
    case "${raw}" in
        0x[0-9a-fA-F]|0x[0-9a-fA-F][0-9a-fA-F])
            val=$(( (raw | 0x01) & 0xff ))
            if i2cset -y -f "${I2C_BUS}" "${PMIC_ADDR}" "${SYS_CFG3_REG}" "${val}" b >/dev/null 2>&1; then
                log "SYS_CFG3 ${raw} -> $(printf '0x%02x' "${val}") DEV_OFF"
            else
                log "SYS_CFG3 write failed (raw=${raw})"
            fi
            ;;
        *)
            log "SYS_CFG3 read failed"
            ;;
    esac
fi

# Give PMIC time to collapse rails before final shutdown sequence continues.
sleep 3
exit 0
RK817_DEVOFF_HOOK
chmod +x "${ROOTFS_MNT}/lib/systemd/system-shutdown/rk817-devoff"

# 10e. Session failsafe watchdog (auto-rollback for risky session tests).
echo "[*] Installing session failsafe watchdog..."
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-session-failsafe.sh" << 'RK_SESSION_FAILSAFE'
#!/bin/sh
set -eu

STATE_DIR=/var/lib/rk-session-failsafe
ARMED_FILE="${STATE_DIR}/armed"
[ -f "${ARMED_FILE}" ] || exit 0

if [ -f /etc/lightdm/lightdm.conf ] && grep -q '^autologin-session=phosh$' /etc/lightdm/lightdm.conf; then
    if loginctl list-sessions --no-legend 2>/dev/null | awk '$3=="chaos"{found=1} END{exit(found?0:1)}'; then
        if pgrep -u chaos -f '/usr/libexec/phosh' >/dev/null 2>&1 || \
           pgrep -u chaos -x phoc >/dev/null 2>&1; then
            rm -f "${ARMED_FILE}"
            logger -t rk-session-failsafe "Phosh session detected; disarmed watchdog without rollback"
            exit 0
        fi
    fi
fi

install -d /etc/lightdm /etc/X11 /etc/systemd/system
cat > /etc/lightdm/lightdm.conf << 'LIGHTDM_CONF'
[LightDM]
minimum-vt=1

[Seat:*]
type=local
user-session=phosh
autologin-user=chaos
autologin-session=phosh
session-wrapper=/etc/X11/Xsession

[XDMCPServer]

[VNCServer]
LIGHTDM_CONF
rm -rf /etc/sddm.conf.d
printf '%s\n' '/usr/sbin/lightdm' > /etc/X11/default-display-manager
ln -sfn /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
ln -sfn /dev/null /etc/systemd/system/getty@tty1.service
systemctl disable sddm >/dev/null 2>&1 || true
systemctl enable lightdm >/dev/null 2>&1 || true
rm -f "${ARMED_FILE}"
logger -t rk-session-failsafe "Rollback to phosh triggered; rebooting"
systemctl --no-block reboot
RK_SESSION_FAILSAFE
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-session-failsafe.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-session-failsafe.service" << 'RK_SESSION_FAILSAFE_UNIT'
[Unit]
Description=Rollback tablet display manager if Phosh test is still armed
ConditionPathExists=/var/lib/rk-session-failsafe/armed
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-session-failsafe.sh
RK_SESSION_FAILSAFE_UNIT

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-session-failsafe.timer" << 'RK_SESSION_FAILSAFE_TIMER'
[Unit]
Description=Run tablet display-manager failsafe 5 minutes after boot

[Timer]
OnBootSec=5min
Unit=rk-session-failsafe.service

[Install]
WantedBy=timers.target
RK_SESSION_FAILSAFE_TIMER

mkdir -p "${ROOTFS_MNT}/var/lib/rk-session-failsafe"
chroot "${ROOTFS_MNT}" systemctl enable rk-session-failsafe.timer

# 11. Offline update package auto-apply service
echo "[*] Installing offline update auto-apply service..."
mkdir -p "${ROOTFS_MNT}/usr/local/sbin"
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-apply-update.sh" << 'RK_APPLY_UPDATE'
#!/bin/bash
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
LOG_FILE="/var/log/rk-update.log"
INBOX_DIRS=(/update/pending /home/chaos/update)
COMPAT_FILE="/update/update.tar.gz"
ARCHIVE_DIR="/update/applied"
FAILED_DIR="/update/failed"
DUPLICATE_DIR="/update/duplicate"
STATE_DIR="/var/lib/rk-update"
STAMP_FILE="${STATE_DIR}/last_applied.sha256"
TMP_DIR=""
BOOT_WAS_MOUNTED=0
BOOT_PART_DEV=""
REBOOT_NEEDED=0
HEARTBEAT_PID=""
PKG_FILE=""

mkdir -p "${STATE_DIR}"
touch "${LOG_FILE}"
exec >> "${LOG_FILE}" 2>&1

say() {
    local msg="$*"
    local line="[$(date -Iseconds)] rk-apply-update: ${msg}"
    echo "${line}"
}

hide_boot_splash() {
    if command -v plymouth >/dev/null 2>&1; then
        plymouth quit 2>/dev/null || true
    fi
    systemctl stop plymouth-start.service plymouth-quit.service plymouth-quit-wait.service 2>/dev/null || true
}

start_heartbeat() {
    (
        while true; do
            sleep 15
            say "Update in progress... do not power off."
        done
    ) &
    HEARTBEAT_PID=$!
}

stop_heartbeat() {
    if [ -n "${HEARTBEAT_PID}" ]; then
        kill "${HEARTBEAT_PID}" 2>/dev/null || true
        wait "${HEARTBEAT_PID}" 2>/dev/null || true
        HEARTBEAT_PID=""
    fi
}

archive_package() {
    local src="$1"
    local dst_dir="$2"
    local suffix="$3"
    local base
    local name
    local ts
    base="$(basename "${src}")"
    case "${base}" in
        *.tar.gz) name="${base%.tar.gz}" ;;
        *.tgz) name="${base%.tgz}" ;;
        *) name="${base}" ;;
    esac
    ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${dst_dir}"
    mv -f "${src}" "${dst_dir}/${name}-${suffix}-${ts}.tar.gz"
}

find_update_package() {
    local dir
    local latest=""
    local candidate

    # Backward-compatible path used by older updater revisions.
    if [ -f "${COMPAT_FILE}" ]; then
        echo "${COMPAT_FILE}"
        return 0
    fi

    for dir in "${INBOX_DIRS[@]}"; do
        [ -d "${dir}" ] || continue
        candidate="$(find "${dir}" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tgz' \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2- || true)"
        [ -n "${candidate}" ] || continue
        if [ -z "${latest}" ]; then
            latest="${candidate}"
            continue
        fi
        if [ "${candidate}" -nt "${latest}" ]; then
            latest="${candidate}"
        fi
    done

    [ -n "${latest}" ] || return 1
    echo "${latest}"
}

echo "=== $(date -Iseconds) rk-apply-update: start ==="
say "Checking for offline update package..."

cleanup() {
    stop_heartbeat
    if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
        rm -rf "${TMP_DIR}"
    fi
    if [ "${BOOT_WAS_MOUNTED}" -eq 1 ] && mountpoint -q /boot; then
        umount /boot || true
    fi
}
trap cleanup EXIT

PKG_FILE="$(find_update_package || true)"
if [ -z "${PKG_FILE}" ]; then
    say "No update package found in: ${INBOX_DIRS[*]}"
    exit 0
fi

say "Found update package: ${PKG_FILE}"
hide_boot_splash
say "Applying update package now."
start_heartbeat

PKG_SUM="$(sha256sum "${PKG_FILE}" | awk '{print $1}')"
if [ -f "${STAMP_FILE}" ] && grep -qx "${PKG_SUM}" "${STAMP_FILE}"; then
    archive_package "${PKG_FILE}" "${DUPLICATE_DIR}" "duplicate" || true
    say "Package ${PKG_SUM} already applied; moved duplicate package."
    exit 0
fi

TMP_DIR="$(mktemp -d /var/tmp/rk-update.XXXXXX)"
if ! tar -xzf "${PKG_FILE}" -C "${TMP_DIR}"; then
    archive_package "${PKG_FILE}" "${FAILED_DIR}" "extract-failed" || true
    say "Failed to extract ${PKG_FILE}; moved package to ${FAILED_DIR}."
    exit 1
fi

if [ ! -d "${TMP_DIR}/rootfs" ] && [ ! -d "${TMP_DIR}/boot" ]; then
    archive_package "${PKG_FILE}" "${FAILED_DIR}" "invalid-layout" || true
    say "Package missing both rootfs/ and boot/ payloads; moved to ${FAILED_DIR}."
    exit 1
fi

if [ -d "${TMP_DIR}/rootfs" ]; then
    say "Applying rootfs payload..."
    tar -C "${TMP_DIR}/rootfs" -cpf - . | tar -C / -xpf -
    say "Rootfs payload applied."
fi

find_boot_partition() {
    local candidate root_part disk part_num boot_num

    for candidate in /dev/disk/by-partlabel/boot /dev/disk/by-label/BOOT /dev/disk/by-label/boot; do
        if [ -e "${candidate}" ]; then
            readlink -f "${candidate}"
            return 0
        fi
    done

    root_part="$(findmnt -n -o SOURCE / || true)"
    case "${root_part}" in
        /dev/mmcblk*p[0-9]*|/dev/nvme*n[0-9]p[0-9]*)
            disk="${root_part%p*}"
            part_num="${root_part##*p}"
            ;;
        /dev/sd[a-z][0-9]*|/dev/vd[a-z][0-9]*|/dev/xvd[a-z][0-9]*)
            disk="${root_part%[0-9]*}"
            part_num="${root_part##*[!0-9]}"
            ;;
        *)
            return 1
            ;;
    esac

    if [ -z "${disk}" ] || [ -z "${part_num}" ] || [ "${part_num}" -le 1 ]; then
        return 1
    fi
    boot_num=$((part_num - 1))

    case "${root_part}" in
        /dev/mmcblk*p[0-9]*|/dev/nvme*n[0-9]p[0-9]*)
            candidate="${disk}p${boot_num}"
            ;;
        *)
            candidate="${disk}${boot_num}"
            ;;
    esac

    [ -b "${candidate}" ] || return 1
    echo "${candidate}"
    return 0
}

if [ -d "${TMP_DIR}/boot" ]; then
    if ! mountpoint -q /boot; then
        BOOT_PART_DEV="$(find_boot_partition || true)"
        if [ -n "${BOOT_PART_DEV}" ]; then
            mkdir -p /boot
            if mount "${BOOT_PART_DEV}" /boot; then
                BOOT_WAS_MOUNTED=1
            else
                say "Failed to mount boot partition ${BOOT_PART_DEV}; skipping boot payload."
            fi
        else
            say "Unable to resolve boot partition; skipping boot payload."
        fi
    fi

    if mountpoint -q /boot; then
        say "Applying boot payload..."
        mkdir -p /boot/extlinux
        if [ -f "${TMP_DIR}/boot/Image" ]; then
            install -m 0644 "${TMP_DIR}/boot/Image" /boot/Image
            REBOOT_NEEDED=1
        fi
        if [ -f "${TMP_DIR}/boot/rk3562.dtb" ]; then
            install -m 0644 "${TMP_DIR}/boot/rk3562.dtb" /boot/rk3562.dtb
            REBOOT_NEEDED=1
        fi
        if [ -f "${TMP_DIR}/boot/rk3562-fallback.dtb" ]; then
            install -m 0644 "${TMP_DIR}/boot/rk3562-fallback.dtb" /boot/rk3562-fallback.dtb
            REBOOT_NEEDED=1
        fi
        if [ -f "${TMP_DIR}/boot/extlinux/extlinux.conf" ]; then
            install -m 0644 "${TMP_DIR}/boot/extlinux/extlinux.conf" /boot/extlinux/extlinux.conf
            REBOOT_NEEDED=1
        fi
        sync
        say "Boot payload applied."
    fi
fi

echo "${PKG_SUM}" > "${STAMP_FILE}"
chmod 0600 "${STAMP_FILE}" || true

mkdir -p "${ARCHIVE_DIR}"
PKG_BASE="$(basename "${PKG_FILE}")"
case "${PKG_BASE}" in
    *.tar.gz) PKG_BASE="${PKG_BASE%.tar.gz}" ;;
    *.tgz) PKG_BASE="${PKG_BASE%.tgz}" ;;
esac
APPLIED_FILE="${ARCHIVE_DIR}/${PKG_BASE}-applied-$(date +%Y%m%d-%H%M%S).tar.gz"
mv -f "${PKG_FILE}" "${APPLIED_FILE}"
sync

say "Update applied successfully; archived package as ${APPLIED_FILE}"

# Rootfs payload may replace binaries/libraries used by current boot. Reboot
# once after apply to ensure a clean and consistent runtime state.
REBOOT_NEEDED=1
if [ "${REBOOT_NEEDED}" -eq 1 ]; then
    stop_heartbeat
    say "Rebooting to finalize update..."
    systemctl --no-block reboot
fi

exit 0
RK_APPLY_UPDATE
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-apply-update.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-apply-update.service" << 'RK_APPLY_UPDATE_UNIT'
[Unit]
Description=Apply offline update package from /update/pending or /update
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target graphical.target
ConditionPathExists=/usr/local/sbin/rk-apply-update.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-apply-update.sh
TimeoutSec=0
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
RK_APPLY_UPDATE_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rk-apply-update.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/rk-apply-update.service"

mkdir -p "${ROOTFS_MNT}/update/pending" "${ROOTFS_MNT}/update/applied" "${ROOTFS_MNT}/update/failed" "${ROOTFS_MNT}/update/duplicate"
cat > "${ROOTFS_MNT}/update/README.txt" << 'RK_UPDATE_README'
Drop update package in one of these folders:
- /update/pending  (recommended)
- /home/chaos/update

No extra command is needed.
On next boot, rk-apply-update.service applies the newest .tar.gz/.tgz package automatically.
Compatibility: /update/update.tar.gz is also checked.
During apply, plymouth spinner is stopped and progress is logged in /var/log/rk-update.log.
RK_UPDATE_README
chroot "${ROOTFS_MNT}" chown -R chaos:chaos /update || true
chroot "${ROOTFS_MNT}" chmod 0775 /update || true
chroot "${ROOTFS_MNT}" install -d -m 0775 -o chaos -g chaos /home/chaos/update || true

# 12. Expand rootfs service
echo "[*] Adding first-boot rootfs expand..."
cat > "${ROOTFS_MNT}/usr/local/bin/expand-rootfs.sh" << 'EXPAND'
#!/bin/bash
exec > /var/log/expand-rootfs.log 2>&1
ROOT_PART=$(findmnt -n -o SOURCE /)
DISK=${ROOT_PART%p[0-9]*}
PARTNUM=${ROOT_PART##*p}
if [ -z "$DISK" ] || [ -z "$PARTNUM" ]; then exit 1; fi
if ! command -v growpart >/dev/null 2>&1 || ! command -v sgdisk >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y cloud-guest-utils gdisk e2fsprogs || true
fi
sgdisk -e "$DISK" || true
growpart "$DISK" "$PARTNUM" || true
partprobe "$DISK" 2>/dev/null || true
sleep 1
resize2fs "$ROOT_PART" || true
systemctl disable expand-rootfs.service
EXPAND
chmod +x "${ROOTFS_MNT}/usr/local/bin/expand-rootfs.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/expand-rootfs.service" << 'SVCUNIT'
[Unit]
Description=Expand rootfs to fill SD card
After=multi-user.target
ConditionPathExists=/usr/local/bin/expand-rootfs.sh

[Service]
Type=oneshot
ExecStart=/usr/local/bin/expand-rootfs.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCUNIT

chroot "${ROOTFS_MNT}" systemctl enable expand-rootfs.service
chroot "${ROOTFS_MNT}" bash -c 'apt-get install -y cloud-guest-utils gdisk 2>/dev/null || true'

# 12. Serial console
echo "[*] Enabling serial console ttyS0..."
mkdir -p "${ROOTFS_MNT}/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/serial-getty@.service \
    "${ROOTFS_MNT}/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"

# 13. Cleanup package caches to reduce rootfs size before image packing
echo "[*] Cleaning apt caches and temporary files..."
chroot "${ROOTFS_MNT}" bash -c 'apt-get clean || true'
rm -rf "${ROOTFS_MNT}/var/cache/apt/archives/"* 2>/dev/null || true
rm -rf "${ROOTFS_MNT}/var/lib/apt/lists/"* 2>/dev/null || true
rm -rf "${ROOTFS_MNT}/tmp/"* 2>/dev/null || true
rm -rf "${ROOTFS_MNT}/var/tmp/"* 2>/dev/null || true

# Optional aggressive slimming for release artifacts.
if [ "${RKDEBIAN_MINIMIZE_IMAGE}" = "1" ]; then
    echo "[*] Applying minimize profile (locales/docs/help/man pruning)..."
    chroot "${ROOTFS_MNT}" bash -c '
        find /usr/share/locale -mindepth 1 -maxdepth 1 \
            ! -name "en" ! -name "en_*" ! -name "locale.alias" \
            -exec rm -rf {} + 2>/dev/null || true
        rm -rf /usr/share/doc/* /usr/share/help/* /usr/share/man/* /usr/share/info/* 2>/dev/null || true
        if command -v flatpak >/dev/null 2>&1; then
            flatpak uninstall --system -y --unused >/dev/null 2>&1 || true
            flatpak repair --system >/dev/null 2>&1 || true
        fi
    '
fi

chroot_cleanup
trap - EXIT

echo "[*] Rootfs creation complete."
