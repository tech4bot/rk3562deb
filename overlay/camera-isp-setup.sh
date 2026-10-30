#!/bin/bash
# camera-isp-setup.sh — configure front camera through RKISP on RK3562 tablet.
#
# Route: s5k5e8 sensor → DPHY4 → MIPI-CSI2 → rkcif-mipi-lvds2 → rkisp-isp-subdev
#        → rkisp_selfpath → /dev/video23
#
# After this script:
# - front link (lvds2) is selected on rkisp input
# - ISP sink/source pads are pinned to 2592x1944
# - optional manual sensor controls are applied (helps when no rkaiq/3A daemon)
#
# Called once at boot by camera-isp-setup.service.

set -euo pipefail

log() { echo "[camera-isp-setup] $*"; }

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: missing required command: $cmd"
        exit 1
    fi
}

require_cmd media-ctl

run_user_systemctl() {
    local action="$1"
    local unit="$2"
    local user uid

    # Case 1: script is run as a regular user with an active user bus.
    if systemctl --user "${action}" "${unit}" >/dev/null 2>&1; then
        return 0
    fi

    # Case 2: script is run as root (boot service) and we can target a user bus.
    if [ "$(id -u)" -ne 0 ]; then
        return 1
    fi
    user="${CAMERA_USER:-@RKDEBIAN_USER@}"
    uid="$(id -u "${user}" 2>/dev/null || true)"
    if [ -z "${uid}" ] || [ ! -S "/run/user/${uid}/bus" ]; then
        return 1
    fi

    if command -v runuser >/dev/null 2>&1; then
        runuser -u "${user}" -- env \
            XDG_RUNTIME_DIR="/run/user/${uid}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
            systemctl --user "${action}" "${unit}" >/dev/null 2>&1
        return $?
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo -u "${user}" env \
            XDG_RUNTIME_DIR="/run/user/${uid}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
            systemctl --user "${action}" "${unit}" >/dev/null 2>&1
        return $?
    fi

    return 1
}

stop_user_camera_services() {
    [ "${FRONT_STOP_USER_SERVICES:-1}" = "1" ] || return 0

    local stopped=0
    if run_user_systemctl stop rkcam-webcam.service; then
        log "stopped user service: rkcam-webcam.service"
        stopped=1
    fi
    if run_user_systemctl stop rkisp1-awb.service; then
        log "stopped user service: rkisp1-awb.service"
        stopped=1
    fi
    if [ "${stopped}" -eq 1 ]; then
        sleep 0.3
    fi
}

start_user_camera_services() {
    [ "${FRONT_RESTART_USER_SERVICES:-1}" = "1" ] || return 0

    # The bridge starts rkisp1-awb itself while a client uses the camera.
    if run_user_systemctl start rkcam-webcam.service; then
        log "started user service: rkcam-webcam.service"
    fi
}

find_isp_media() {
    local dev
    local topo
    for dev in /dev/media0 /dev/media1 /dev/media2; do
        [ -e "$dev" ] || continue
        topo="$(media-ctl -d "$dev" -p 2>/dev/null || true)"
        if [[ "${topo}" == *"rkisp-isp-subdev"* ]]; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

MEDIA_DEV=""
for _ in $(seq 1 30); do
    MEDIA_DEV="$(find_isp_media || true)"
    [ -n "${MEDIA_DEV}" ] && break
    sleep 1
done

if [ -z "${MEDIA_DEV}" ]; then
    log "ERROR: no rkisp media controller found after waiting"
    exit 1
fi
log "ISP media controller: ${MEDIA_DEV}"

set_link() {
    local spec="$1"
    local i
    for i in $(seq 1 20); do
        if media-ctl -d "${MEDIA_DEV}" --links "${spec}" >/dev/null 2>&1; then
            log "link ok: ${spec}"
            return 0
        fi
        sleep 0.2
    done
    log "ERROR: failed to apply media link after retries: ${spec}"
    return 1
}

set_pad() {
    local spec="$1"
    local i
    for i in $(seq 1 20); do
        if media-ctl -d "${MEDIA_DEV}" --set-v4l2 "${spec}" >/dev/null 2>&1; then
            log "pad ok: ${spec}"
            return 0
        fi
        sleep 0.2
    done
    log "ERROR: failed to apply pad format/crop after retries: ${spec}"
    return 1
}

# 1) Select front camera link into ISP.
stop_user_camera_services

if ! set_link '"rkcif-mipi-lvds":0 -> "rkisp-isp-subdev":0 [0]'; then
    log "WARNING: could not disable rear ISP link (often busy if already switched)"
fi
if ! set_link '"rkcif-mipi-lvds2":0 -> "rkisp-isp-subdev":0 [1]'; then
    log "WARNING: could not force-enable front ISP link; validating current topology"
fi

# 2) Pin front-camera dimensions/formats on input and ISP output.
set_pad '"rkcif-mipi-lvds2":0[fmt:SGRBG10_1X10/2592x1944]'
set_pad '"rkisp-isp-subdev":0[fmt:SGRBG10_1X10/2592x1944 crop:(0,0)/2592x1944]'
set_pad '"rkisp-isp-subdev":2[fmt:YUYV8_2X8/2592x1944 crop:(0,0)/2592x1944]'

MEDIA_TOPOLOGY="$(media-ctl -d "${MEDIA_DEV}" -p 2>/dev/null || true)"
if [[ "${MEDIA_TOPOLOGY}" != *'<- "rkcif-mipi-lvds2":0 [ENABLED]'* ]]; then
    log "ERROR: front link was not enabled after setup"
    exit 1
fi
log "front link verified: rkcif-mipi-lvds2 -> rkisp-isp-subdev"

# 3) Force ISP sink/source via ioctl helper (handles stale crop state on some boots).
ISP_SUBDEV="$(media-ctl -d "${MEDIA_DEV}" -p 2>/dev/null | awk '
    /^- entity [0-9]+: rkisp-isp-subdev / { in_entity = 1; next }
    in_entity && /device node name/ { print $NF; found = 1; exit }
    in_entity && /^- entity [0-9]+:/ { exit }
    END { if (!found) print "" }
')"

if [ -z "${ISP_SUBDEV}" ]; then
    ISP_SUBDEV="/dev/v4l-subdev7"
    log "WARNING: fallback ISP subdev path: ${ISP_SUBDEV}"
else
    log "ISP subdev: ${ISP_SUBDEV}"
fi

if [ -x /usr/local/bin/config_isp ]; then
    if ! /usr/local/bin/config_isp "${ISP_SUBDEV}" 2>&1 | sed 's/^/[camera-isp-setup] /'; then
        log "WARNING: config_isp failed, continuing with media-ctl state"
    fi
else
    log "WARNING: /usr/local/bin/config_isp not found — skipping ioctl crop reset"
fi

# 4) Apply manual front-sensor controls unless disabled.
# This keeps the image visible on images where no rkaiq/3A daemon is running.
if command -v v4l2-ctl >/dev/null 2>&1; then
    SENSOR_SUBDEV="${FRONT_SENSOR_SUBDEV:-/dev/v4l-subdev6}"
    if [ "${FRONT_FORCE_MANUAL:-1}" = "1" ] && [ -e "${SENSOR_SUBDEV}" ]; then
        FRONT_EXPOSURE="${FRONT_EXPOSURE:-1964}"
        FRONT_ANALOG_GAIN="${FRONT_ANALOG_GAIN:-1024}"
        v4l2-ctl -d "${SENSOR_SUBDEV}" -c test_pattern=0 >/dev/null 2>&1 || true
        v4l2-ctl -d "${SENSOR_SUBDEV}" -c exposure="${FRONT_EXPOSURE}" >/dev/null 2>&1 || true
        v4l2-ctl -d "${SENSOR_SUBDEV}" -c analogue_gain="${FRONT_ANALOG_GAIN}" >/dev/null 2>&1 || true
        log "manual sensor controls applied (exposure=${FRONT_EXPOSURE}, gain=${FRONT_ANALOG_GAIN})"
    else
        log "manual sensor controls skipped (FRONT_FORCE_MANUAL=${FRONT_FORCE_MANUAL:-1})"
    fi
fi

start_user_camera_services

log "Front camera ISP pipeline ready. Use /dev/video23 for preview/webcam"
