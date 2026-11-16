#!/bin/bash
# Packages build/Avadhana.app into build/Avadhana.dmg: a disk image with the app and an
# Applications shortcut, so installing is a drag and drop.
# Signs the disk image when DMG_SIGN_IDENTITY is set (notarize.sh does this).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Avadhana.app
DMG=build/Avadhana.dmg
if [ ! -d "$APP" ]; then
  echo "build/Avadhana.app not found. Run ./build.sh first." >&2
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Avadhana.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
# `diskutil image` replaces hdiutil on newer macOS; fall back to hdiutil on older systems.
if diskutil image create from --help >/dev/null 2>&1; then
  diskutil image create from --format UDZO --volumeName "Avadhana $VERSION" "$STAGE" "$DMG" >/dev/null
else
  hdiutil create -volname "Avadhana $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
fi

if [ -n "${DMG_SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$DMG_SIGN_IDENTITY" "$DMG"
fi
echo "Packaged $DMG (version $VERSION)"
