#!/bin/zsh
# Sets the version everywhere it appears and bumps the build number.
# Usage: scripts/set-version.sh 1.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

NEW="${1:-}"
if [[ ! "$NEW" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "Usage: scripts/set-version.sh X.Y.Z" >&2
  exit 1
fi

PLIST=Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
perl -pi -e "s/(static let version = \")[^\"]*/\${1}$NEW/; s/(static let build = \")[^\"]*/\${1}$BUILD/" \
  Sources/StorageKeeperCore/Version.swift

echo "Version $NEW (build $BUILD)"
