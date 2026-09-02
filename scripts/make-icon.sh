#!/bin/bash
# Turn Resources/AppIcon.svg (or any square 1024px image you pass) into
# Resources/AppIcon.icns. build.sh picks the .icns up automatically.
#
#   ./scripts/make-icon.sh                  # from Resources/AppIcon.svg
#   ./scripts/make-icon.sh path/to/icon.png # from a generated 1024x1024 PNG
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${1:-Resources/AppIcon.svg}"
WORK="$(mktemp -d)"
ICONSET="${WORK}/AppIcon.iconset"
RENDER="${WORK}/render.swift"
mkdir -p "$ICONSET"

cat > "$RENDER" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]),
      let image = NSImage(contentsOf: URL(fileURLWithPath: args[1]))
else { FileHandle.standardError.write(Data("usage: render <in> <out.png> <px>\n".utf8)); exit(1) }
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
SWIFT

for px in 16 32 64 128 256 512 1024; do
    swift "$RENDER" "$SOURCE" "${WORK}/${px}.png" "$px"
done
cp "${WORK}/16.png"   "${ICONSET}/icon_16x16.png"
cp "${WORK}/32.png"   "${ICONSET}/icon_16x16@2x.png"
cp "${WORK}/32.png"   "${ICONSET}/icon_32x32.png"
cp "${WORK}/64.png"   "${ICONSET}/icon_32x32@2x.png"
cp "${WORK}/128.png"  "${ICONSET}/icon_128x128.png"
cp "${WORK}/256.png"  "${ICONSET}/icon_128x128@2x.png"
cp "${WORK}/256.png"  "${ICONSET}/icon_256x256.png"
cp "${WORK}/512.png"  "${ICONSET}/icon_256x256@2x.png"
cp "${WORK}/512.png"  "${ICONSET}/icon_512x512.png"
cp "${WORK}/1024.png" "${ICONSET}/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "${WORK}/1024.png" "${SCRATCH_PREVIEW:-/dev/null}" 2>/dev/null || true
rm -rf "$WORK"
echo "Wrote Resources/AppIcon.icns"
