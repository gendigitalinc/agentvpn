#!/bin/bash
# Copies PI model assets from a local Sage installation.
#
# The model files originate from the Sage project's ML model distribution.
# If you have Sage installed, run this script to copy the model files
# into the pi-ml-scan assets directory for compilation.
#
# Alternative: place model_int8.onnx, tokenizer.json, and config.json
# manually in tools/pi-ml-scan/assets/.
set -euo pipefail

ASSETS_DIR="$(cd "$(dirname "$0")/assets" && pwd)"
SAGE_MODEL_DIR="${SAGE_MODEL_DIR:-$HOME/.sage/models/v1/pi-model}"

if [ ! -d "$SAGE_MODEL_DIR" ]; then
    echo "ERROR: Sage PI model not found at $SAGE_MODEL_DIR"
    echo "Either install Sage and run it once to download the model,"
    echo "or set SAGE_MODEL_DIR to point to the model directory."
    exit 1
fi

mkdir -p "$ASSETS_DIR"

for f in model_int8.onnx tokenizer.json config.json; do
    if [ ! -f "$SAGE_MODEL_DIR/$f" ]; then
        echo "ERROR: Missing $f in $SAGE_MODEL_DIR"
        exit 1
    fi
    cp "$SAGE_MODEL_DIR/$f" "$ASSETS_DIR/$f"
    echo "  [copied] $f"
done

echo "Done. Assets:"
ls -lh "$ASSETS_DIR"
