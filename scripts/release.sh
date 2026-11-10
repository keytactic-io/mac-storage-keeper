#!/bin/zsh
# Builds release artifacts into ./dist:
#   StorageKeeper-<version>.dmg        universal app (Apple Silicon + Intel), drag to Applications
#   skeeper-<version>-macos.zip        universal CLI
#   SHA256SUMS.txt
#
# Usage:
#   scripts/release.sh             build artifacts only
#   scripts/release.sh --publish   also tag v<version>, push the tag, and create a GitHub release (needs `gh`)
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=Resources/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
CODE_VERSION=$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' Sources/StorageKeeperCore/Version.swift)
if [[ "$VERSION" != "$CODE_VERSION" ]]; then
  echo "Version mismatch: Info.plist $VERSION vs Version.swift $CODE_VERSION. Run scripts/set-version.sh." >&2
  exit 1
fi
TAG="v$VERSION"
echo "Releasing Storage Keeper $VERSION"

# Universal binaries: build each architecture, then merge (works without full Xcode).
for T in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
  swift build -c release --triple "$T"
done
ARM=$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)
X86=$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)

DIST=dist
STAGE="$DIST/stage.noindex"
rm -rf "$DIST"
mkdir -p "$STAGE"

APP="$STAGE/Storage Keeper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PLIST" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
lipo -create "$ARM/StorageKeeper" "$X86/StorageKeeper" -output "$APP/Contents/MacOS/StorageKeeper"
lipo -create "$ARM/skeeper" "$X86/skeeper" -output "$STAGE/skeeper"

# Same local certificate as development builds, so Full Disk Access survives updates.
scripts/make-signing-cert.sh
IDENTITY="Storage Keeper Local Signing"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --force --sign "$IDENTITY" --identifier local.storagekeeper.skeeper --timestamp=none "$STAGE/skeeper"
codesign --verify --strict "$APP"
codesign --verify --strict "$STAGE/skeeper"

# DMG with the app and an Applications shortcut.
DMGSRC="$STAGE/dmg"
mkdir -p "$DMGSRC"
cp -R "$APP" "$DMGSRC/"
ln -s /Applications "$DMGSRC/Applications"
hdiutil create -quiet -volname "Storage Keeper $VERSION" -srcfolder "$DMGSRC" -fs HFS+ -format UDZO \
  "$DIST/StorageKeeper-$VERSION.dmg"

# CLI zip with just the binary at the top level (the signature is embedded in the binary).
(cd "$STAGE" && zip -q -X "../skeeper-$VERSION-macos.zip" skeeper)

(cd "$DIST" && shasum -a 256 StorageKeeper-$VERSION.dmg skeeper-$VERSION-macos.zip > SHA256SUMS.txt)
rm -rf "$STAGE"

echo "Artifacts:"
ls -lh "$DIST"
lipo -info "$APP" 2>/dev/null || true

if [[ "${1:-}" == "--publish" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree has uncommitted changes; commit them before publishing." >&2
    exit 1
  fi
  if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists. Bump the version with scripts/set-version.sh." >&2
    exit 1
  fi
  git tag -a "$TAG" -m "Storage Keeper $VERSION"
  git push origin "$TAG"
  NOTES="docs/release-notes/$TAG.md"
  if [[ -f "$NOTES" ]]; then NOTE_ARGS=(--notes-file "$NOTES"); else NOTE_ARGS=(--generate-notes); fi
  gh release create "$TAG" "$DIST/StorageKeeper-$VERSION.dmg" "$DIST/skeeper-$VERSION-macos.zip" "$DIST/SHA256SUMS.txt" \
    --title "Storage Keeper $VERSION" "${NOTE_ARGS[@]}"
fi
