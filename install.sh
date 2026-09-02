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
if pgrep -x "ClipboardAnnotator" >/dev/null 2>&1; then
    echo "    Existing copy did not quit; stopping it now"
    pkill -KILL -x "ClipboardAnnotator"
fi

echo "==> Installing to ${DEST}"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "==> Launching"
# Force a new instance. Without -n, Launch Services can target the copy that
# just quit and return kLSApplicationNotFoundErr (-600).
open -n "$DEST"
for _ in $(seq 1 40); do
    pgrep -x "ClipboardAnnotator" >/dev/null 2>&1 && break
    sleep 0.1
done
pgrep -x "ClipboardAnnotator" >/dev/null 2>&1 || {
    echo "Launch failed: ClipboardAnnotator did not start" >&2
    exit 1
}

echo
echo "Look for the speech-bubble icon in the menu bar."
echo "If this is the first run, grant Accessibility when asked:"
echo "  System Settings → Privacy & Security → Accessibility"
