#!/bin/bash
# Build the public Mac download: Release, universal, ad-hoc signed, packed in a DMG.
#   scripts/build-mac-release.sh            -> dist/OM-Photos.dmg (+ versioned copy)
# The free developer account cannot sign with Developer ID, so users open it the
# first time from System Settings > Privacy & Security > "Open Anyway".
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(grep -E '^\s+MARKETING_VERSION:' project.yml | head -1 | awk '{print $2}')
OUT=dist
rm -rf build/release "$OUT"
mkdir -p "$OUT"
xcodegen generate >/dev/null
xcodebuild -project OMPhotos.xcodeproj -scheme OMPhotos-macOS -configuration Release \
  -derivedDataPath build/release -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  CODE_SIGN_ENTITLEMENTS=App/macOS/OMPhotos-public.entitlements \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="build/release/Build/Products/Release/OM Photos.app"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "OM Photos $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/OM-Photos.dmg"
rm -rf "$STAGE"
cp "$OUT/OM-Photos.dmg" "$OUT/OM-Photos-$VERSION.dmg"
shasum -a 256 "$OUT"/*.dmg
lipo -archs "$APP/Contents/MacOS/OM Photos"
