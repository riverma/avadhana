#!/bin/bash
# Builds, signs with your Developer ID, packages a DMG, notarizes it with Apple and staples the
# ticket. Output: build/Avadhana.dmg, ready to attach to a GitHub release.
#
# One-time setup:
#   1. Create a "Developer ID Application" certificate (Account Holder only): at
#      https://developer.apple.com/account/resources/certificates, upload a certificate request made
#      in Keychain Access, then add the downloaded certificate to your login keychain
#   2. Create an app-specific password at https://account.apple.com (Sign-In and Security), then:
#        xcrun notarytool store-credentials avadhana-notary --apple-id <your Apple ID> --team-id <your team ID>
set -euo pipefail
cd "$(dirname "$0")"
PROFILE="${NOTARY_PROFILE:-avadhana-notary}"

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [ -z "$IDENTITY" ]; then
  echo "No \"Developer ID Application\" certificate found. See the setup steps at the top of this script." >&2
  exit 1
fi

CODESIGN_IDENTITY="$IDENTITY" ./build.sh
DMG_SIGN_IDENTITY="$IDENTITY" ./package-dmg.sh
DMG=build/Avadhana.dmg

echo "Submitting to Apple's notary service (usually a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Notarized: $DMG"
