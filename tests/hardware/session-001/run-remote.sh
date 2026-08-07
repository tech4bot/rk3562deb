#!/usr/bin/env bash
# run-remote.sh — Conrad-side wrapper for session-001 hardware validation.
#
# Conrad cannot resolve the `samwise` mDNS hostname (WSL2 limitation, see
# docs/wiki/01-hardware-baseline.md), so this takes the tablet's current
# DHCP IP as a parameter. scp's capture-matrix.sh to the tablet, runs it
# there over SSH, and pulls the resulting evidence directory back into
# tests/hardware/session-001/evidence/.
#
# This script never flashes anything and never touches /dev/mmcblk2 — it
# only copies one script out and one evidence directory back.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'USAGE'
Usage: run-remote.sh --host <ip-or-user@ip> [--user <user>] [--port <port>]

Run session-001's capture-matrix.sh on the booted candidate and pull the
evidence directory back to tests/hardware/session-001/evidence/.

Options:
  --host <ip|user@ip>   Tablet address (required). Bare IP is fine, e.g.
                         192.168.11.167 — --user is applied in that case.
  --user <user>         SSH user if --host was a bare IP (default: frodo)
  --port <port>         SSH port (default: 22)
  -h, --help            Show this help

Example:
  ./run-remote.sh --host 192.168.11.167
  ./run-remote.sh --host frodo@192.168.11.167
USAGE
    exit "${1:-0}"
}

HOST_ARG=""
SSH_USER="frodo"
SSH_PORT=22

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST_ARG="$2"; shift 2 ;;
        --user) SSH_USER="$2"; shift 2 ;;
        --port) SSH_PORT="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1"; usage 1 ;;
    esac
done

if [[ -z "$HOST_ARG" ]]; then
    echo "ERROR: --host is required (tablet IP; Conrad cannot resolve 'samwise')"
    usage 1
fi

if [[ "$HOST_ARG" == *@* ]]; then
    SSH_TARGET="$HOST_ARG"
else
    SSH_TARGET="${SSH_USER}@${HOST_ARG}"
fi

SSH_CMD=(ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o BatchMode=yes "$SSH_TARGET")
SCP_CMD=(scp -P "$SSH_PORT" -o ConnectTimeout=10 -o BatchMode=yes)

echo "=== session-001 remote capture ==="
echo "Target: $SSH_TARGET:$SSH_PORT"
echo "Date:   $(date -Iseconds)"
echo ""

echo "-- Checking SSH connectivity --"
if ! "${SSH_CMD[@]}" "echo ok" >/dev/null 2>&1; then
    echo "ERROR: Cannot reach $SSH_TARGET on port $SSH_PORT."
    echo "  - Confirm the candidate SD card actually booted (see README.md"
    echo "    'if boot goes dark' section for serial console recovery)."
    echo "  - The IP is DHCP-assigned; re-check it if the tablet rebooted."
    exit 1
fi
echo "OK"
echo ""

echo "-- Copying capture-matrix.sh to the tablet (~/session-001-capture-matrix.sh) --"
"${SCP_CMD[@]}" "$SCRIPT_DIR/capture-matrix.sh" "${SSH_TARGET}:~/session-001-capture-matrix.sh"
"${SSH_CMD[@]}" "chmod +x ~/session-001-capture-matrix.sh"
echo ""

echo "-- Running capture-matrix.sh on the tablet --"
echo "   (each row is isolated; a failing row will not abort the run)"
echo ""
REMOTE_LOG_FILE="$(mktemp)"
trap 'rm -f "$REMOTE_LOG_FILE"' EXIT

set +e
"${SSH_CMD[@]}" "~/session-001-capture-matrix.sh" | tee "$REMOTE_LOG_FILE"
REMOTE_RC=${PIPESTATUS[0]}
set -e

if [[ "$REMOTE_RC" -ne 0 ]]; then
    echo ""
    echo "WARNING: capture-matrix.sh exited rc=$REMOTE_RC on the tablet. Rows are"
    echo "isolated from each other by design, so this alone does not mean total"
    echo "failure — check summary.txt below before drawing conclusions."
fi

REMOTE_EVID_DIR="$(awk -F': ' '/^Evidence directory:/{print $2; exit}' "$REMOTE_LOG_FILE")"
if [[ -z "$REMOTE_EVID_DIR" ]]; then
    echo ""
    echo "ERROR: could not parse the remote evidence directory path from capture-matrix.sh output."
    echo "Check the tablet by hand: ls ~/validation/"
    exit 1
fi

LOCAL_EVID_ROOT="$SCRIPT_DIR/evidence"
LOCAL_EVID_DIR="$LOCAL_EVID_ROOT/$(basename "$REMOTE_EVID_DIR")"
mkdir -p "$LOCAL_EVID_ROOT"

echo ""
echo "-- Pulling evidence directory back to $LOCAL_EVID_DIR --"
"${SCP_CMD[@]}" -r "${SSH_TARGET}:${REMOTE_EVID_DIR}" "$LOCAL_EVID_ROOT/"

echo ""
echo "=== Remote capture complete ==="
echo "Local evidence: $LOCAL_EVID_DIR"
echo "Summary:        $LOCAL_EVID_DIR/summary.txt"
echo ""
if [[ -f "$LOCAL_EVID_DIR/summary.txt" ]]; then
    cat "$LOCAL_EVID_DIR/summary.txt"
fi
echo ""
echo "Next steps:"
echo "  1. Open each MANUAL row's evidence file and close it out by hand"
echo "     (display content, touch feel, suspend-window observation, etc.)."
echo "  2. Run the dedicated NPU kit for rows 17-18 (candidate/SD-boot procedure):"
echo "     $SCRIPT_DIR/../npu-smoke-test/deploy-to-candidate.sh ${HOST_ARG#*@}"
echo "     ssh $SSH_TARGET '~/npu-smoke-test/run-candidate-smoke.sh'"
echo "  3. Record date, image reference, and final per-row pass/fail in"
echo "     docs/HARDWARE_TEST_MATRIX.md (scribe's job, not this script's)."
echo ""
echo "NOTE: the remote copy at ${SSH_TARGET}:${REMOTE_EVID_DIR} was left in"
echo "place on the tablet; it is small text output, not evidence of any write"
echo "to eMMC. Remove it by hand later if you want to tidy up ~/validation/."
