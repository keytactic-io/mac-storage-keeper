#!/bin/zsh
# Builds Storage Keeper.app and the skeeper CLI into ./build
# Usage: scripts/build-app.sh [--install]   (--install copies the app to /Applications and the CLI to ~/.local/bin)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

# Spotlight skips folders ending in ".noindex", so this build copy doesn't show up
# next to the installed one when you search for the app.
APP="build/app.noindex/Storage Keeper.app"
rm -rf "build/Storage Keeper.app" "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Regenerate the icon with: swift scripts/make-icon.swift dark Resources && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/StorageKeeper" "$APP/Contents/MacOS/StorageKeeper"
cp "$BIN/skeeper" build/skeeper

# Sign with a stable local certificate so Full Disk Access survives rebuilds
# (an ad-hoc signature changes every build and macOS would drop the permission).
scripts/make-signing-cert.sh
IDENTITY="Storage Keeper Local Signing"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --force --sign "$IDENTITY" --identifier local.storagekeeper.skeeper --timestamp=none build/skeeper

echo "Built: $APP"
echo "Built: build/skeeper"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x StorageKeeper 2>/dev/null || true
  rm -rf "/Applications/Storage Keeper.app"
  cp -R "$APP" /Applications/
  mkdir -p ~/.local/bin
  cp build/skeeper ~/.local/bin/skeeper
  echo "Installed /Applications/Storage Keeper.app and ~/.local/bin/skeeper"
  open "/Applications/Storage Keeper.app"
fi
