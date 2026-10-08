#!/bin/zsh
# Compila en release y empaqueta HexLens.app en ./dist (y opcionalmente en /Applications con --install).
# HEXLENS_VERSION y HEXLENS_BUILD fijan la versión del bundle (las usa el workflow de release).
# HEXLENS_SIGN_IDENTITY firma con Developer ID (p. ej. "Developer ID Application: Nombre (TEAMID)"); sin ella, firma ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${HEXLENS_VERSION:-0.0.0-dev}"
BUILD="${HEXLENS_BUILD:-1}"
SIGN_IDENTITY="${HEXLENS_SIGN_IDENTITY:-}"
swift build -c release --product HexLens
swift build -c release --product hexlens-cli
APP=dist/HexLens.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/HexLens "$APP/Contents/MacOS/HexLens"
cp .build/release/hexlens-cli dist/hexlens
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>HexLens</string>
  <key>CFBundleDisplayName</key><string>HexLens</string>
  <key>CFBundleIdentifier</key><string>dev.hexlens.app</string>
  <key>CFBundleExecutable</key><string>HexLens</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [[ -n "$SIGN_IDENTITY" ]]; then
  # Hardened runtime y timestamp: lo que pide la notarización de Apple.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" dist/hexlens
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/HexLens.app && cp -R "$APP" /Applications/
  echo "Instalada en /Applications/HexLens.app"
fi
echo "$APP"
