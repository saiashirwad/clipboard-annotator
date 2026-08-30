#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Clipboard Annotator"
BUNDLE_ID="com.texoport.ClipboardAnnotator"
BUILD_DIR=".build/release"
DIST="dist/${APP_NAME}.app"

echo "==> Building"
swift build -c release

echo "==> Assembling ${DIST}"
rm -rf "dist"
mkdir -p "${DIST}/Contents/MacOS" "${DIST}/Contents/Resources"
cp "${BUILD_DIR}/ClipboardAnnotator" "${DIST}/Contents/MacOS/ClipboardAnnotator"
cp "Resources/Info.plist" "${DIST}/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${DIST}/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${DIST}/Contents/Info.plist" 2>/dev/null || true
fi

# A stable signing identity keeps the Accessibility grant across rebuilds.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -m1 -E "Developer ID Application|Apple Development" \
        | sed -E 's/.*"(.*)".*/\1/' || true)
fi
if [ -n "$IDENTITY" ]; then
    echo "==> Signing with: ${IDENTITY}"
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "${DIST}"
else
    echo "==> No signing identity found; signing ad-hoc"
    echo "    (macOS will re-ask for Accessibility after each rebuild)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "${DIST}"
fi

codesign --verify --verbose=1 "${DIST}"
echo
echo "Built: ${DIST}"
echo "Install with: ./install.sh"
