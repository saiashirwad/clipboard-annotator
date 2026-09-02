#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Clipboard Annotator"
BUNDLE_ID="com.texoport.ClipboardAnnotator"
BIN_DIR=$(swift build -c release --show-bin-path)
DIST="dist/${APP_NAME}.app"
PLIST="${DIST}/Contents/Info.plist"
ENTITLEMENTS="Resources/ClipboardAnnotator.entitlements"

# Version comes from Resources/Info.plist (release.sh bumps it). The build
# number is the commit count, so every build is distinguishable.
APP_VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)}"
APP_BUILD="${APP_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

echo "==> Building ${APP_VERSION} (${APP_BUILD})"
swift build -c release

echo "==> Assembling ${DIST}"
rm -rf "dist"
mkdir -p "${DIST}/Contents/MacOS" "${DIST}/Contents/Resources"
cp "${BIN_DIR}/ClipboardAnnotator" "${DIST}/Contents/MacOS/ClipboardAnnotator"
cp "Resources/Info.plist" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_BUILD}" "${PLIST}"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${DIST}/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${PLIST}" 2>/dev/null || true
fi

# A stable signing identity keeps the Accessibility grant across rebuilds.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
    IDENTITY=$(printf '%s\n' "$IDENTITIES" \
        | grep -m1 "Developer ID Application" \
        | sed -E 's/.*"(.*)".*/\1/' || true)
    if [ -z "$IDENTITY" ]; then
        IDENTITY=$(printf '%s\n' "$IDENTITIES" \
            | grep -m1 "Apple Development" \
            | sed -E 's/.*"(.*)".*/\1/' || true)
    fi
fi

# Every build gets the hardened runtime and the same entitlements, so a dev
# build behaves exactly like the notarized one. Only real identities can carry
# a secure timestamp, which notarization requires.
SIGN_FLAGS=(--force --options runtime --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID")
if [ "$IDENTITY" = "-" ]; then
    echo "==> Signing ad-hoc"
    echo "    (macOS will ask users to approve this build before opening it)"
    codesign "${SIGN_FLAGS[@]}" --sign - "${DIST}"
elif [ -n "$IDENTITY" ]; then
    echo "==> Signing with: ${IDENTITY}"
    codesign "${SIGN_FLAGS[@]}" --timestamp --sign "$IDENTITY" "${DIST}"
else
    echo "==> No signing identity found; signing ad-hoc"
    echo "    (macOS will re-ask for Accessibility after each rebuild)"
    codesign "${SIGN_FLAGS[@]}" --sign - "${DIST}"
fi

codesign --verify --verbose=1 "${DIST}"
echo
echo "Built: ${DIST}"
echo "Install with: ./install.sh"
