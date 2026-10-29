#!/bin/sh
# make-app.sh — build SpeedColorsUI and package it as dist/SpeedColors.app.
#
# The bundle is what makes it a first-class macOS menu bar app: LSUIElement
# keeps it off the Dock (the SwiftUI MenuBarExtra supplies the status item),
# and the stable bundle id means Accessibility/Screen Recording grants stick
# across rebuilds instead of re-prompting for every rebuilt raw binary.
#
# Usage:  tools/make-app.sh            → dist/SpeedColors.app
#         open dist/SpeedColors.app    → launch into the menu bar
set -e
cd "$(dirname "$0")/.."

./dev.sh build

EXE=.build/out/Products/Debug/SpeedColorsUI
APP=dist/SpeedColors.app
[ -x "$EXE" ] || { echo "✗ $EXE missing — build failed?" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXE" "$APP/Contents/MacOS/SpeedColors"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>SpeedColors</string>
    <key>CFBundleDisplayName</key>       <string>SpeedColors</string>
    <key>CFBundleIdentifier</key>        <string>io.github.speedcolors.ui</string>
    <key>CFBundleExecutable</key>        <string>SpeedColors</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

# Let the packaged app resolve dylibs/libraries from its own location too.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ $APP"
echo "  → open it with:  open $APP"
