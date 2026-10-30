#!/bin/bash
# setup_isp_rear.sh — configure rear camera (s5k4h5yb) through ISP.
#
# Route: s5k4h5yb -> DPHY0 -> MIPI CSI2 -> rkcif-mipi-lvds -> rkisp -> /dev/video22
# Default mode is 1632x1224: the whole sensor, 2x2 binned. 1920x1080 is a
# center crop (zoomed), and the ISP cannot keep up with full 3264x2448.
#
# Key fix:
#   We must set the rear CIF pad format on the ISP media graph
#   ("rkcif-mipi-lvds":0). If this is left stale from front-camera setup
#   (2592x1944), rear output can appear gray/striped.
#
# Usage:
#   bash setup_isp_rear.sh
#
# Optional env:
#   REAR_W=1632 REAR_H=1224
#   ISP_VIDEO_DEV=/dev/video22
#   REAR_SENSOR_SUBDEV=/dev/v4l-subdev2
#   REAR_FOCUS_SUBDEV=/dev/v4l-subdev3
#   REAR_FOCUS=64
#   REAR_SENSOR_ENTITY="m00_b_s5k4h5yb 4-0036"
set -euo pipefail

W="${REAR_W:-1632}"
H="${REAR_H:-1224}"
ISP_VIDEO_DEV="${ISP_VIDEO_DEV:-/dev/video22}"
ISP_SUBDEV="${ISP_SUBDEV:-/dev/v4l-subdev7}"
SENSOR_SUBDEV="${REAR_SENSOR_SUBDEV:-/dev/v4l-subdev2}"
FOCUS_SUBDEV="${REAR_FOCUS_SUBDEV:-/dev/v4l-subdev3}"

log() {
    echo "[setup_isp_rear] $*"
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: missing required command: $cmd"
        exit 1
    fi
}

find_media_with_entity() {
    local entity_pat="$1"
    local dev
    local topo
    for dev in /dev/media0 /dev/media1 /dev/media2 /dev/media3; do
        [ -e "$dev" ] || continue
        topo="$(media-ctl -d "$dev" -p 2>/dev/null || true)"
        if [[ "${topo}" == *"${entity_pat}"* ]]; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

find_entity_name() {
    local media_dev="$1"
    local entity_pat="$2"
    media-ctl -d "${media_dev}" -p 2>/dev/null | awk -v pat="${entity_pat}" '
        /^- entity [0-9]+:/ {
            name = $0
            sub(/^- entity [0-9]+: /, "", name)
            sub(/ \([0-9]+ pads?.*/, "", name)
            if (name ~ pat) {
                print name
                exit
            }
        }
    '
}

set_link() {
    local media_dev="$1"
    local spec="$2"
    local i
    for i in $(seq 1 20); do
        if media-ctl -d "${media_dev}" --links "${spec}" >/dev/null 2>&1; then
            log "link ok: ${spec}"
            return 0
        fi
        sleep 0.2
    done
    log "ERROR: failed media link after retries: ${spec}"
    return 1
}

set_pad() {
    local media_dev="$1"
    local spec="$2"
    local i
    for i in $(seq 1 20); do
        if media-ctl -d "${media_dev}" --set-v4l2 "${spec}" >/dev/null 2>&1; then
            log "pad ok: ${spec}"
            return 0
        fi
        sleep 0.2
    done
    log "ERROR: failed pad format/crop after retries: ${spec}"
    return 1
}

require_cmd media-ctl
require_cmd v4l2-ctl

ISP_MEDIA="${ISP_MEDIA:-$(find_media_with_entity 'rkisp-isp-subdev' || true)}"
REAR_MEDIA="${REAR_MEDIA:-$(find_media_with_entity 'rockchip-csi2-dphy0' || true)}"

if [ -z "${REAR_MEDIA}" ] && [ -e /dev/media0 ]; then
    REAR_MEDIA="/dev/media0"
    log "WARN: rear media auto-detect failed, falling back to ${REAR_MEDIA}"
fi

if [ -z "${ISP_MEDIA}" ]; then
    log "ERROR: could not find ISP media device (entity: rkisp-isp-subdev)"
    exit 1
fi
if [ -z "${REAR_MEDIA}" ]; then
    log "ERROR: could not find rear camera media device (entity: rockchip-csi2-dphy0)"
    exit 1
fi

log "ISP media device: ${ISP_MEDIA}"
log "Rear media device: ${REAR_MEDIA}"

if [ ! -e "${ISP_SUBDEV}" ]; then
    auto_isp_subdev="$(media-ctl -d "${ISP_MEDIA}" -p 2>/dev/null \
        | awk '
            /rkisp-isp-subdev/ {seen=1}
            seen && /device node name/ {print $NF; exit}
        ')"
    if [ -n "${auto_isp_subdev}" ]; then
        ISP_SUBDEV="${auto_isp_subdev}"
    fi
fi
log "ISP subdev path: ${ISP_SUBDEV}"

REAR_SENSOR_ENTITY="${REAR_SENSOR_ENTITY:-$(find_entity_name "${REAR_MEDIA}" "s5k4h5yb" || true)}"
if [ -n "${REAR_SENSOR_ENTITY}" ]; then
    log "Rear sensor entity: ${REAR_SENSOR_ENTITY}"
else
    log "WARN: rear sensor entity name not found in topology; continuing without explicit sensor pad set."
fi

if [ ! -e "${ISP_VIDEO_DEV}" ] && [ "${ISP_VIDEO_DEV}" = "/dev/video22" ] && [ -e /dev/video23 ]; then
    ISP_VIDEO_DEV="/dev/video23"
fi
log "Capture node: ${ISP_VIDEO_DEV}"

echo "=== Step 1: Free the ISP from the front camera ==="
# The front bridge only opens the camera while an app uses it; stop it only
# then (the app loses the front camera). Restarting it otherwise would give
# its PipeWire source a new id that open apps no longer find.
if fuser -s /dev/video23 2>/dev/null; then
    systemctl --user stop rkisp1-awb.service rkcam-webcam.service 2>/dev/null &&
        log "Stopped front camera bridge (front camera was in use)" || true
    sleep 0.3
fi

echo ""
echo "=== Step 2: Switch ISP input from front -> rear ==="
if ! set_link "${ISP_MEDIA}" '"rkcif-mipi-lvds2":0 -> "rkisp-isp-subdev":0 [0]'; then
    log "WARN: could not explicitly disable lvds2 link; continuing"
fi
REAR_ISP_LINKED=1
if ! set_link "${ISP_MEDIA}" '"rkcif-mipi-lvds":0 -> "rkisp-isp-subdev":0 [1]'; then
    log "WARN: rear->ISP link switch was rejected by kernel; falling back to raw rear capture"
    REAR_ISP_LINKED=0
fi

if [ "${REAR_ISP_LINKED}" = "1" ]; then
    echo ""
    echo "=== Step 3: Pin rear CIF + CSI formats (${W}x${H}) ==="
    # Critical: pin the rear CIF pad on ISP media graph to avoid stale front format.
    set_pad "${ISP_MEDIA}" '"rkcif-mipi-lvds":0[fmt:SGRBG10_1X10/'"${W}x${H}"']'

    # Rear raw chain on DPHY0/MIPI0 media graph.
    if [ -n "${REAR_SENSOR_ENTITY}" ]; then
        set_pad "${REAR_MEDIA}" "\"${REAR_SENSOR_ENTITY}\":0[fmt:SGRBG10_1X10/${W}x${H}]"
    fi
    set_pad "${REAR_MEDIA}" '"rockchip-csi2-dphy0":0[fmt:SGRBG10_1X10/'"${W}x${H}"']'
    if ! set_pad "${REAR_MEDIA}" '"rockchip-csi2-dphy0":1[fmt:SGRBG10_1X10/'"${W}x${H}"']'; then
        log "WARN: optional pad setup failed: rockchip-csi2-dphy0:1"
    fi
    set_pad "${REAR_MEDIA}" '"rockchip-mipi-csi2":0[fmt:SGRBG10_1X10/'"${W}x${H}"']'
    if ! set_pad "${REAR_MEDIA}" '"rockchip-mipi-csi2":1[fmt:SGRBG10_1X10/'"${W}x${H}"']'; then
        log "WARN: optional pad setup failed: rockchip-mipi-csi2:1"
    fi
fi

if [ "${REAR_ISP_LINKED}" = "1" ]; then
    echo ""
    echo "=== Step 4: Force ISP sink/source formats via ioctl helper ==="
    if [ -x /usr/local/bin/config_isp ]; then
        /usr/local/bin/config_isp "${ISP_SUBDEV}" "${W}" "${H}"
    else
        log "ERROR: /usr/local/bin/config_isp not found"
        exit 1
    fi
fi

echo ""
echo "=== Step 5: Apply rear sensor controls ==="
if [ -e "${SENSOR_SUBDEV}" ]; then
    REAR_EXPOSURE="${REAR_EXPOSURE:-2448}"
    # Fixed exposure (there is no auto exposure); 256 (8x) suits indoor light
    # in the binned 1632x1224 mode, 768 blows it out.
    REAR_ANALOG_GAIN="${REAR_ANALOG_GAIN:-256}"
    v4l2-ctl -d "${SENSOR_SUBDEV}" -c test_pattern=0 >/dev/null 2>&1 || true
    v4l2-ctl -d "${SENSOR_SUBDEV}" -c exposure="${REAR_EXPOSURE}" >/dev/null 2>&1 || true
    v4l2-ctl -d "${SENSOR_SUBDEV}" -c analogue_gain="${REAR_ANALOG_GAIN}" >/dev/null 2>&1 || true
    log "Sensor controls applied: exposure=${REAR_EXPOSURE} analogue_gain=${REAR_ANALOG_GAIN}"
else
    log "WARN: sensor subdev missing (${SENSOR_SUBDEV}); skipping manual controls"
fi

# Optional manual lens focus (VCM). Rear module exposes focus_absolute on fp5510.
# Note: the fp5510 driver powers the coil only while its node is open, so this
# position lasts only until v4l2-ctl exits; rkcam-rear-view.py keeps the node
# open and runs autofocus.
if [ -e "${FOCUS_SUBDEV}" ]; then
    REAR_FOCUS="${REAR_FOCUS:-64}"
    # v4l2-ctl exits non-zero (and prints an error on stdout) on these subdevs
    # even when the control works: the vendor kernel lacks
    # VIDIOC_SUBDEV_S_CLIENT_CAP. Check the value instead.
    get_focus() {
        v4l2-ctl -d "${FOCUS_SUBDEV}" --get-ctrl=focus_absolute 2>/dev/null |
            sed -n 's/^focus_absolute: //p' || true
    }
    if [ -n "$(get_focus)" ]; then
        v4l2-ctl -d "${FOCUS_SUBDEV}" -c focus_absolute="${REAR_FOCUS}" >/dev/null 2>&1 || true
        if [ "$(get_focus)" = "${REAR_FOCUS}" ]; then
            log "Lens focus applied: focus_absolute=${REAR_FOCUS}"
        else
            log "WARN: failed to apply focus_absolute=${REAR_FOCUS} on ${FOCUS_SUBDEV}"
        fi
    else
        log "WARN: focus_absolute control not available on ${FOCUS_SUBDEV}"
    fi
else
    log "WARN: focus subdev missing (${FOCUS_SUBDEV}); skipping lens focus"
fi

# No AWB feeder for the rear camera: rkisp1-awb carries the front camera's
# white balance (and, being bound to the front bridge, would restart it).

echo ""
if [ "${REAR_ISP_LINKED}" = "1" ]; then
    echo "=== Step 7: Capture 1 frame from ${ISP_VIDEO_DEV} ==="
else
    echo "=== Step 7: Capture 1 frame from rear raw node (/dev/video0) ==="
fi
TS="$(date +%Y%m%d_%H%M%S)"
if [ "${REAR_ISP_LINKED}" = "1" ]; then
    OUTFILE="/tmp/rear_isp_${TS}.raw"
    v4l2-ctl -d "${ISP_VIDEO_DEV}" \
        --set-fmt-video="width=${W},height=${H},pixelformat=NV12" \
        --stream-mmap 3 --stream-skip 8 --stream-count 1 --stream-to "${OUTFILE}" 2>&1
else
    OUTFILE="/tmp/rear_raw_${TS}.raw"
    v4l2-ctl -d /dev/video0 \
        --set-fmt-video="width=${W},height=${H},pixelformat=BA10" \
        --stream-mmap 3 --stream-skip 8 --stream-count 1 --stream-to "${OUTFILE}" 2>&1
fi

if [ -f "${OUTFILE}" ]; then
    size="$(stat -c%s "${OUTFILE}" 2>/dev/null || echo 0)"
    if [ "${REAR_ISP_LINKED}" = "1" ]; then
        expected=$((W * H * 3 / 2))
    else
        expected=$((W * H * 2))
    fi
    echo ""
    echo "Captured: ${OUTFILE} (${size} bytes)"
    if [ "${REAR_ISP_LINKED}" = "1" ]; then
        echo "Expected NV12 size: ${expected} bytes"
    else
        echo "Expected BA10-in-16bit size: ${expected} bytes (driver may pack differently)"
    fi
    echo "Analyze on host:"
    echo "  scp chaos@192.168.2.109:${OUTFILE} ."
    if [ "${REAR_ISP_LINKED}" = "1" ]; then
        echo "  python3 tools/analyze_raw.py --w ${W} --h ${H} --fmt nv12 $(basename "${OUTFILE}")"
    else
        echo "  python3 tools/analyze_raw.py --w ${W} --h ${H} $(basename "${OUTFILE}")"
    fi
else
    log "ERROR: capture file not created"
    exit 1
fi

echo ""
echo "=== ISP link state ==="
media-ctl -d "${ISP_MEDIA}" --print-topology 2>/dev/null | \
    grep -E '(rkcif-mipi-lvds|rkisp-isp-subdev.*0|ENABLED|DISABLED)' | head -12 || true
