#!/bin/sh
# dev.sh — swift wrapper for Command Line Tools setups.
#
# CLT's 27.0 SDK implements SwiftUI property wrappers (@State, @Binding, …)
# as macros, but CLT does not ship the SwiftUIMacros plugin, so any SwiftUI
# target fails with "plugin for module 'SwiftUIMacros' not found". The 26.5
# SDK still uses plain property wrappers, so we fall back to it until the
# plugin shows up (future CLT update, or full Xcode install).
#
# Usage:  ./dev.sh build | ./dev.sh run SpeedColorsUI | ./dev.sh run -q speedcolors status
set -e
CLT=/Library/Developer/CommandLineTools
if [ -f "$CLT/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
    exec swift "$@"
fi
SDK="$CLT/SDKs/MacOSX26.5.sdk"
[ -d "$SDK" ] || SDK="$CLT/SDKs/MacOSX26.sdk"
SDKROOT="$SDK" exec swift "$@"
