#!/usr/bin/env bash
# dock-mode.sh: Configure external monitor as primary and tablet as dock controller

ACTION="${1:-toggle}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

find_external_display() {
    wlr-randr 2>/dev/null | grep -E '^[A-Za-z0-9-]+' | grep -v 'DSI-1' | awk '{print $1}' | head -n 1
}

enable_dock_mode() {
    EXT_DISP="$(find_external_display)"
    if [ -z "${EXT_DISP}" ]; then
        echo "[-] No external display found via wlr-randr."
        return 1
    fi

    echo "[*] Found external display: ${EXT_DISP}"
    
    # 1. Configure external display at 0,0 (primary) and tablet display at 1920,0
    wlr-randr --output "${EXT_DISP}" --preferred --pos 0,0 --output DSI-1 --pos 1920,0 || true
    sleep 0.5

    # 2. Pre-grant camera & microphone permissions to prevent blocking portal dialogs
    for app in "" "chromium" "chromium.desktop"; do
        gdbus call --session --dest org.freedesktop.impl.portal.PermissionStore \
            --object-path /org/freedesktop/impl/portal/PermissionStore \
            --method org.freedesktop.impl.portal.PermissionStore.SetPermission \
            'devices' true 'camera' "${app}" "['yes']" >/dev/null 2>&1 || true
        gdbus call --session --dest org.freedesktop.impl.portal.PermissionStore \
            --object-path /org/freedesktop/impl/portal/PermissionStore \
            --method org.freedesktop.impl.portal.PermissionStore.SetPermission \
            'devices' true 'microphone' "${app}" "['yes']" >/dev/null 2>&1 || true
    done

    # 3. Kill any stale dock pad instances
    pkill -f "tablet-dock-pad.py" || true

    # 3. Launch tablet dock controller on tablet screen
    python3 /usr/local/bin/tablet-dock-pad.py >/dev/null 2>&1 &
    echo "[+] Dock mode enabled."
}

disable_dock_mode() {
    echo "[*] Disabling dock mode..."
    pkill -f "tablet-dock-pad.py" || true

    # Dismiss any transient xdg-popups (e.g. YouTube search autocomplete) before display rearrangement
    python3 -c "import evdev; ui = evdev.UInput({evdev.ecodes.EV_KEY: [evdev.ecodes.KEY_ESC]}); ui.write(evdev.ecodes.EV_KEY, evdev.ecodes.KEY_ESC, 1); ui.syn(); ui.write(evdev.ecodes.EV_KEY, evdev.ecodes.KEY_ESC, 0); ui.syn(); ui.close()" 2>/dev/null || true
    sleep 0.2

    EXT_DISP="$(find_external_display)"
    if [ -n "${EXT_DISP}" ]; then
        # Reset internal display to 0,0 and external to 1280,0
        wlr-randr --output DSI-1 --pos 0,0 --output "${EXT_DISP}" --pos 1280,0 || true
    else
        wlr-randr --output DSI-1 --pos 0,0 || true
    fi
    echo "[+] Tablet mode restored."
}

case "${ACTION}" in
    enable)
        enable_dock_mode
        ;;
    disable)
        disable_dock_mode
        ;;
    toggle)
        if pgrep -f "tablet-dock-pad.py" >/dev/null; then
            disable_dock_mode
        else
            enable_dock_mode
        fi
        ;;
    *)
        echo "Usage: $0 {enable|disable|toggle}"
        exit 1
        ;;
esac
