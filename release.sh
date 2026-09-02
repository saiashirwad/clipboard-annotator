#!/bin/bash
# Cut a distributable build, entirely from this Mac.
#
#   ./release.sh 1.2            build, notarize, staple, zip
#   ./release.sh 1.2 --publish  ...then tag and create a GitHub release
#
# One-time setup:
#   1. Install a "Developer ID Application" certificate in your keychain
#      (Xcode → Settings → Accounts → Manage Certificates).
#   2. Store notarization credentials, using an app-specific password from
#      appleid.apple.com:
#        xcrun notarytool store-credentials clipboard-annotator \
#            --apple-id you@example.com --team-id TEAMID
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:-}"
PUBLISH=false
[ "${2:-}" = "--publish" ] && PUBLISH=true
if [ -z "$VERSION" ]; then
    echo "usage: ./release.sh VERSION [--publish]" >&2
    exit 1
fi

APP_NAME="Clipboard Annotator"
APP="dist/${APP_NAME}.app"
ARCHIVE="dist/ClipboardAnnotator-${VERSION}.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-clipboard-annotator}"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "No Developer ID Application certificate in the keychain." >&2
    echo "Notarization needs one; see the setup notes at the top of this script." >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "No notarytool credentials under profile '${NOTARY_PROFILE}'." >&2
    echo "Create them with: xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id you@example.com --team-id TEAMID" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree is not clean. Commit or stash first so the build number matches a commit." >&2
    exit 1
fi

echo "==> Stamping version ${VERSION}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" Resources/Info.plist

./build.sh

echo "==> Notarizing"
SUBMISSION="dist/notarize-submission.zip"
ditto -c -k --keepParent "$APP" "$SUBMISSION"
xcrun notarytool submit "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$SUBMISSION"

echo "==> Stapling"
xcrun stapler staple "$APP"
spctl -a -t exec -vv "$APP"

echo "==> Archiving ${ARCHIVE}"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

if [ "$PUBLISH" = true ]; then
    echo "==> Publishing v${VERSION}"
    git add Resources/Info.plist
    git commit -m "Release ${VERSION}" || true
    git tag "v${VERSION}"
    git push && git push origin "v${VERSION}"
    gh release create "v${VERSION}" "$ARCHIVE" --title "${APP_NAME} ${VERSION}" --generate-notes
else
    echo
    echo "Ready: ${ARCHIVE}"
    echo "Resources/Info.plist now says ${VERSION}; commit it, or rerun with --publish to tag and upload."
fi
