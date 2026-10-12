#!/bin/bash
# Builds dist/OneCursor.app (menu bar app + bundled `onecursor` CLI) and a zip of it.
# Usage: scripts/build-app.sh [--universal]
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_ARGS=()
if [[ "${1:-}" == "--universal" ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"

APP=dist/OneCursor.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/OneCursorApp" "$APP/Contents/MacOS/OneCursor"
cp "$BIN/onecursor" "$APP/Contents/MacOS/onecursor"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>One Cursor</string>
    <key>CFBundleDisplayName</key><string>One Cursor</string>
    <key>CFBundleIdentifier</key><string>dev.onecursor.mac</string>
    <key>CFBundleExecutable</key><string>OneCursor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>One Cursor connects to your other computers and phones on the local network.</string>
    <key>NSBonjourServices</key><array><string>_onecursor._tcp</string></array>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS can track the Accessibility permission for this build.
codesign --force --deep --sign - "$APP"

(cd dist && ditto -c -k --keepParent OneCursor.app OneCursor-macos.zip)
echo "Built $APP and dist/OneCursor-macos.zip"
