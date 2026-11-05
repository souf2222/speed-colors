#!/bin/sh
# make-app.sh — build SpeedColors and package it as dist/SpeedColors.app.
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

EXE=.build/debug/SpeedColors
APP=dist/SpeedColors.app
[ -x "$EXE" ] || { echo "✗ $EXE missing — build failed?" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXE" "$APP/Contents/MacOS/SpeedColors"
# The page-watcher sidecar ships inside the bundle — a bundled app launched
# via `open` has CWD "/" and could never find the repo-relative tools/ copy.
cp tools/resolve_page_agent.py "$APP/Contents/Resources/"

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

# Signing matters for privacy grants: macOS keys TCC permissions (Accessibility,
# Screen Recording, Input Monitoring) on the app's signing identity. An ad-hoc
# signature (—) changes cdhash on every rebuild, so each rebuild can re-prompt.
# If a stable local code-signing certificate exists (create one in Keychain
# Access: Certificate Assistant → Create a Certificate → name it e.g.
# "SpeedColors Dev", type Code Signing), sign with it so grants stick across
# rebuilds. Fall back to ad-hoc otherwise.
SIGN_ID="${SPEEDCOLORS_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    # Only genuinely VALID identities (no CSSMERR failures), preferring the
    # project's own stable certificate over unrelated ones.
    valid_ids=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]*[0-9A-Fa-f]+[[:space:]]+"(.*)".*/\1/p')
    SIGN_ID=$(printf '%s\n' "$valid_ids" | grep -m1 '^SpeedColors Dev$' || true)
    [ -n "$SIGN_ID" ] || SIGN_ID=$(printf '%s\n' "$valid_ids" | head -1)
fi
if [ -n "$SIGN_ID" ]; then
    if codesign --force --sign "$SIGN_ID" "$APP" >/dev/null 2>&1; then
        echo "  signed with: $SIGN_ID (privacy grants persist across rebuilds)"
    else
        codesign --force --sign - "$APP" >/dev/null 2>&1 || true
        echo "  signed ad-hoc (certificate '$SIGN_ID' unusable)"
    fi
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    echo "  signed ad-hoc — macOS may re-ask permissions after rebuilds"
    echo "  (create a 'SpeedColors Dev' code-signing certificate to fix permanently)"
fi

echo "✓ $APP"
echo "  → open it with:  open $APP"
