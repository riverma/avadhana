#!/bin/bash
# Builds build/Avadhana.app.
#
# Signing: uses $CODESIGN_IDENTITY if set, otherwise a "Developer ID Application" certificate if you
# have one, otherwise "Apple Development". Always with the hardened runtime (needed for notarization).
# Note: macOS ties the Accessibility permission to the signing identity, so switching identities
# means granting it again once.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f Resources/AppIcon.icns ] || [ Resources/AppIcon.svg -nt Resources/AppIcon.icns ]; then
  echo "Rendering app icon from Resources/AppIcon.svg"
  swift scripts/make-icon.swift Resources/AppIcon.svg Resources/AppIcon.icns
fi
# Universal binary: runs natively on Apple silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"

APP=build/Avadhana.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Avadhana" "$APP/Contents/MacOS/Avadhana"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Build identity from git: the commit hash (shown in Settings, "-modified" if there are uncommitted
# changes), the commit count as the numeric build number macOS requires, and the commit date.
PLIST="$APP/Contents/Info.plist"
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  COMMIT=$(git rev-parse --short HEAD)
  [ -n "$(git status --porcelain --untracked-files=no)" ] && COMMIT="$COMMIT-modified"
  BUILD=$(git rev-list --count HEAD)
  DATE=$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ)
else
  COMMIT="uncommitted"
  BUILD=0
  DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :AvadhanaCommit string $COMMIT" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :AvadhanaDate string $DATE" "$PLIST"

IDENTITIES=$(security find-identity -v -p codesigning)
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(echo "$IDENTITIES" | awk -F'"' '/Developer ID Application/ {print $2; exit}')
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(echo "$IDENTITIES" | awk -F'"' '/Apple Development/ {print $2; exit}')
fi

SIGN_ARGS=(--force --options runtime --sign "${IDENTITY:--}")
if [[ "$IDENTITY" == *"Developer ID"* ]]; then
  SIGN_ARGS+=(--timestamp)   # secure timestamp is required for notarization
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST") (signed with ${IDENTITY:-ad-hoc identity})"
