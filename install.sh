#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Clipboard Annotator"
SRC="dist/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

[ -d "$SRC" ] || { echo "Build it first: ./build.sh"; exit 1; }

echo "==> Quitting any running copy"
pkill -x "ClipboardAnnotator" 2>/dev/null || true
# Wait for it to actually go. Two live copies both own the annotation store
# in memory, and whichever saves last wins — that resurrects deleted notes.
for _ in $(seq 1 40); do
    pgrep -x "ClipboardAnnotator" >/dev/null 2>&1 || break
    sleep 0.1
done

echo "==> Installing to ${DEST}"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "==> Launching"
open "$DEST"

echo
echo "Look for the speech-bubble icon in the menu bar."
echo "If this is the first run, grant Accessibility when asked:"
echo "  System Settings → Privacy & Security → Accessibility"
