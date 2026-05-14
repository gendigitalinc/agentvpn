#!/bin/bash
# In-container two-tier prompt injection scanner.
#
# Tier 1: Heuristic regex scan against a pattern file (fast, ~0ms).
# Tier 2: ML inference via pi-ml-scan binary (BERT-tiny ONNX, ~10-50ms).
#
# Reads content from stdin, checks both tiers, and reports the result via
# exit code. Designed for piping:
#   curl -s <url> | pi-scan.sh
#
# Exit codes:
#   0  — content is clean (or scan failed open); content written to stdout
#   77 — high-confidence PI detected; content suppressed, warning on stderr
#
# Fail-open: any error (missing pattern file, binary not found, model error)
# passes content through unchanged with exit 0.
#
# Environment:
#   PATTERN_FILE    — path to heuristic pattern file (default: /usr/local/share/pi-patterns.txt)
#   PI_ML_SCAN_BIN  — path to ML scanner binary (default: /usr/local/bin/pi-ml-scan)
#   PI_ML_ENABLED   — set to "0" to skip ML tier (default: "1")

PATTERN_FILE="${PATTERN_FILE:-/usr/local/share/pi-patterns.txt}"
PI_ML_SCAN_BIN="${PI_ML_SCAN_BIN:-/usr/local/bin/pi-ml-scan}"
PI_ML_ENABLED="${PI_ML_ENABLED:-1}"

content=$(cat)

if [ -z "$content" ]; then
    exit 0
fi

# --- Tier 1: Heuristic regex scan ---
if [ -f "$PATTERN_FILE" ]; then
    matched_line=$(printf '%s' "$content" | grep -E -i -n -m 1 -f <(grep -v '^#' "$PATTERN_FILE" | grep -v '^$') 2>/dev/null)
    scan_rc=$?

    if [ "$scan_rc" -eq 0 ] && [ -n "$matched_line" ]; then
        line_num="${matched_line%%:*}"
        snippet="${matched_line#*:}"
        if [ "${#snippet}" -gt 120 ]; then
            snippet="${snippet:0:120}..."
        fi
        echo "[pi-scan] BLOCKED (heuristic): prompt injection detected at line ${line_num}: ${snippet}" >&2
        exit 77
    fi
else
    echo "[pi-scan] WARNING: pattern file not found at $PATTERN_FILE; heuristic tier skipped" >&2
fi

# --- Tier 2: ML inference ---
if [ "$PI_ML_ENABLED" = "1" ] && [ -x "$PI_ML_SCAN_BIN" ]; then
    ml_output=$(printf '%s' "$content" | "$PI_ML_SCAN_BIN" 2>/tmp/pi-ml-scan.stderr)
    ml_rc=$?

    if [ "$ml_rc" -eq 77 ]; then
        # Relay the ML scanner's stderr message
        cat /tmp/pi-ml-scan.stderr >&2 2>/dev/null
        rm -f /tmp/pi-ml-scan.stderr
        exit 77
    elif [ "$ml_rc" -ne 0 ]; then
        ml_err=$(cat /tmp/pi-ml-scan.stderr 2>/dev/null)
        echo "[pi-scan] WARNING: ML scanner error (rc=$ml_rc): $ml_err; passing through (fail-open)" >&2
    fi
    rm -f /tmp/pi-ml-scan.stderr
fi

# Both tiers passed (or failed open)
printf '%s' "$content"
exit 0
