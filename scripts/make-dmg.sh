#!/bin/zsh
# Builds Foray for distribution and packs it into dist/Foray-<version>.dmg (drag to Applications).
#
#   scripts/make-dmg.sh
#       Signs with your "Developer ID Application" certificate if you have one (needed for other
#       people's Macs), otherwise "Apple Development" (fine for testing on your own Macs only).
#   FORAY_NOTARY_PROFILE=foray scripts/make-dmg.sh
#       Also notarizes the DMG with Apple and staples the ticket, so it opens without warnings.
#
# One-time setup for notarization (needs the paid Apple Developer Program):
#   1. Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application
#   2. xcrun notarytool store-credentials foray --apple-id <your Apple ID> --team-id <team ID>
#      (asks for an app-specific password from appleid.apple.com)
set -euo pipefail
cd "${0:A:h}/.."

identity=${FORAY_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    identity="Developer ID Application"
  else
    identity="Apple Development"
    print -u2 "warning: no Developer ID Application certificate; this DMG only opens on your own Macs."
  fi
fi
distributable=false
[[ $identity == "Developer ID Application"* ]] && distributable=true

RF_UNIVERSAL=1 RF_SIGN_IDENTITY="$identity" scripts/bundle.sh release >/dev/null
app=.build/Foray.app
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")

# Hardened runtime and a secure timestamp: both required for notarization.
timestamp=--timestamp
$distributable || timestamp=--timestamp=none
codesign --force --options runtime $timestamp --entitlements Resources/Foray.entitlements --sign "$identity" "$app"
codesign --verify --strict --verbose=1 "$app"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
mkdir -p dist
dmg=dist/Foray-$version.dmg
rm -f "$dmg"
hdiutil create -volname "Foray $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
codesign --force $timestamp --sign "$identity" "$dmg"

if [[ -n ${FORAY_NOTARY_PROFILE:-} ]]; then
  $distributable || { print -u2 "error: notarization needs a Developer ID Application certificate."; exit 1; }
  xcrun notarytool submit "$dmg" --keychain-profile "$FORAY_NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi
echo "$dmg"
