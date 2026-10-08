#!/bin/zsh
# Genera Resources/AppIcon.icns a partir de docs/logo.svg. Ejecutar solo al cambiar el logo.
set -euo pipefail
cd "$(dirname "$0")/.."
SVG=docs/logo.svg
OUT=Resources/AppIcon.icns
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET" Resources

cat > "$TMP/render.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
guard let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else { fatalError("No se pudo leer \(args[1])") }
let px = Int(args[2])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
SWIFT
swiftc -O "$TMP/render.swift" -o "$TMP/render" 2>/dev/null

for size in 16 32 128 256 512; do
  "$TMP/render" "$SVG" $size "$ICONSET/icon_${size}x${size}.png"
  "$TMP/render" "$SVG" $((size * 2)) "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$OUT"
echo "$OUT"
