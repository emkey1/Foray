#!/bin/zsh
# Packs Foray into dist/Foray-<version>.dmg (drag to Applications).
#
# Releases (notarized through Xcode, no passwords):
#   1. open Xcode/Foray.xcodeproj, choose the "Foray App" scheme, Product › Archive
#   2. Organizer › Distribute App › Direct Distribution: Xcode signs with Developer ID, notarizes
#      with your Xcode account and exports Foray.app
#   3. scripts/make-dmg.sh /path/to/exported/Foray.app
#
# Without an app argument it builds and signs one itself:
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

# An app exported by Xcode (already signed and notarized): check it and pack it as is.
if [[ $# -ge 1 ]]; then
  app=${1%/}
  [[ -d $app/Contents ]] || { print -u2 "error: $app isn't an app bundle"; exit 1; }
  codesign --verify --strict --verbose=1 "$app"
  if xcrun stapler validate "$app" >/dev/null 2>&1; then
    spctl --assess --type execute --verbose "$app"
  else
    print -u2 "warning: $app has no notarization ticket stapled; other Macs will block it."
  fi
  version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
  stage=$(mktemp -d)
  trap 'rm -rf "$stage"' EXIT
  cp -R "$app" "$stage/"
  ln -s /Applications "$stage/Applications"
  mkdir -p dist
  dmg=dist/Foray-$version.dmg
  rm -f "$dmg"
  hdiutil create -volname "Foray $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
  # The app inside carries the notarization; sign the disk image too if a Developer ID key is here.
  if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    codesign --force --timestamp --sign "Developer ID Application" "$dmg"
  fi
  echo "$dmg"
  exit 0
fi

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
