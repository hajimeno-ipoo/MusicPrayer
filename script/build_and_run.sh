#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_NAME="MusicPrayer"
BUNDLE_ID="com.hazimeno.MusicPrayer"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
swift build
BIN_DIR="$(swift build --show-bin-path)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
if [[ -d "$BIN_DIR/MusicPrayer_MusicPrayer.bundle" ]]; then
  /usr/bin/ditto "$BIN_DIR/MusicPrayer_MusicPrayer.bundle" "$APP_BUNDLE/Contents/Resources/MusicPrayer_MusicPrayer.bundle"
fi
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MusicPrayer</string>
<key>CFBundleIdentifier</key><string>com.hazimeno.MusicPrayer</string>
<key>CFBundleName</key><string>Music Prayer</string>
<key>CFBundleDisplayName</key><string>Music Prayer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Audio</string>
<key>LSItemContentTypes</key><array><string>public.audio</string></array>
<key>CFBundleTypeRole</key><string>Viewer</string>
</dict></array>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP_BUNDLE"
case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "MusicPrayer"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.hazimeno.MusicPrayer"' ;;
  --build-only) ;;
  *) echo "usage: $0 [run|--verify|--debug|--logs|--telemetry|--build-only]" >&2; exit 2 ;;
esac
