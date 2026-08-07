#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    cat <<'USAGE'
Usage: collect-target-test-report.sh --host <user@host> [--port <port>] [--output <dir>]

Collect a hardware test report from a running candidate image on samwise.
This runs the same collection as the baseline capture, then compares against
the stored baseline to detect regressions.

Options:
  --host <user@host>    SSH target (required)
  --port <port>         SSH port (default: 22)
  --output <dir>        Output directory (default: auto-timestamped under manifests/)
  -h, --help            Show this help
USAGE
    exit "${1:-0}"
}

SSH_HOST=""
SSH_PORT=22
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) SSH_HOST="$2"; shift 2 ;;
        --port) SSH_PORT="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1"; usage 1 ;;
    esac
done

if [[ -z "$SSH_HOST" ]]; then
    echo "ERROR: --host is required"
    usage 1
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$PROJECT_ROOT/manifests/images/test-report_${TIMESTAMP}"
fi

echo "=== Target Test Report Collection ==="
echo "Target: $SSH_HOST"
echo "Output: $OUTPUT_DIR"
echo ""

# Capture candidate state using the baseline script
"$SCRIPT_DIR/capture-samwise-baseline.sh" \
    --host "$SSH_HOST" \
    --port "$SSH_PORT" \
    --output-dir "$OUTPUT_DIR/candidate-state"

# Run comparison if baseline exists
BASELINE_DIR="$PROJECT_ROOT/baseline/current-system"
if [[ -d "$BASELINE_DIR" && -f "$BASELINE_DIR/manifest.json" ]]; then
    echo ""
    echo "--- Running Baseline Comparison ---"
    if [[ -f "$SCRIPT_DIR/compare-baselines.py" ]]; then
        python3 "$SCRIPT_DIR/compare-baselines.py" \
            --baseline "$BASELINE_DIR" \
            --candidate "$OUTPUT_DIR/candidate-state" \
            --output "$OUTPUT_DIR/comparison-report.json" \
            --human "$OUTPUT_DIR/comparison-report.txt" \
        && echo "Comparison report: $OUTPUT_DIR/comparison-report.txt" \
        || echo "WARNING: Comparison script failed (check $SCRIPT_DIR/compare-baselines.py)"
    else
        echo "WARNING: compare-baselines.py not found, skipping comparison"
    fi
else
    echo "WARNING: No baseline found for comparison. Run capture-samwise-baseline.sh first."
fi

echo ""
echo "=== Test Report Collection Complete ==="
echo "Report: $OUTPUT_DIR"
echo ""
echo "Next steps:"
echo "  1. Review comparison-report.txt for regressions"
echo "  2. Update manifest test_status field"
echo "  3. Record results in docs/HARDWARE_TEST_MATRIX.md"
