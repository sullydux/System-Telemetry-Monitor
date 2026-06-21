#!/usr/bin/env bash
#
# build.sh — build the System Monitor Dashboard .app bundle from the CLI.
#
# Requires only macOS Command Line Tools (no Xcode needed):
#   xcode-select --install
#
# Usage:
#   ./build.sh            # release build + bundle + ad-hoc sign
#   ./build.sh debug      # debug build (faster compile, slower runtime)
#   ./build.sh run        # build, then launch the app
#
set -euo pipefail

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
APP_NAME="System Monitor Dashboard"
EXEC_NAME="SystemMonitorDashboard"          # SwiftPM executable target name
BUNDLE_ID="com.sullybase.system-monitor-dashboard"
CONFIG="release"
RUN_AFTER=0

if [[ "${1:-}" == "debug" ]]; then CONFIG="debug"; fi
if [[ "${1:-}" == "run" ]];    then CONFIG="release"; RUN_AFTER=1; fi

# Resolve paths relative to this script so it works from any cwd.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

SWIFT_BIN="$(command -v swift)" || { echo "swift not found. Run: xcode-select --install"; exit 1; }

# -----------------------------------------------------------------------------
# 1. Compile via SwiftPM
# -----------------------------------------------------------------------------
echo "==> Building ($CONFIG) with $SWIFT_BIN"
"$SWIFT_BIN" build -c "$CONFIG"

# SwiftPM lays out build artifacts here. Show the path in case it changes.
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
BUILT_EXEC="$BIN_PATH/$EXEC_NAME"
[[ -f "$BUILT_EXEC" ]] || { echo "Build succeeded but $BUILT_EXEC is missing"; exit 1; }

# -----------------------------------------------------------------------------
# 2. Assemble the .app bundle
# -----------------------------------------------------------------------------
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "==> Assembling bundle: $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy the compiled executable in as the bundle's main binary.
cp "$BUILT_EXEC" "$MACOS_DIR/$EXEC_NAME"

# Copy the Info.plist descriptor into Contents/.
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

# Add a minimal PkgInfo (8 bytes: 'APPL????') — expected by some LaunchServices paths.
printf 'APPL????' > "$CONTENTS/PkgInfo"

# -----------------------------------------------------------------------------
# 3. Ad-hoc codesign (local-only; no paid developer account required)
# -----------------------------------------------------------------------------
echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || \
    echo "   warning: codesign failed — the app still runs locally but may show a Gatekeeper prompt"

# -----------------------------------------------------------------------------
# 4. Done
# -----------------------------------------------------------------------------
echo
echo "✓ Build complete"
echo "  Binary : $MACOS_DIR/$EXEC_NAME"
echo "  App    : $APP_DIR"
echo
echo "Open it with:"
echo "  open \"$APP_DIR\""
[[ "$RUN_AFTER" -eq 0 ]] && exit 0

# -----------------------------------------------------------------------------
# (optional) launch
# -----------------------------------------------------------------------------
echo "==> Launching"
open "$APP_DIR"
