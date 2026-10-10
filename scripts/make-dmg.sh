#!/bin/zsh
# Makes the installer, dist/Foray-<version>.dmg: a window with Foray and an Applications shortcut
# side by side over a background that says what to do, and Foray's icon on the disk.
#
# Releases (Developer ID signing and notarization happen in Xcode, with your Xcode account):
#   1. open Xcode/Foray.xcodeproj, "Foray App" scheme, Product › Archive
#   2. Organizer › Distribute App › Direct Distribution, and wait for "Ready to distribute"
#   3. scripts/make-dmg.sh
#      With no argument it exports the notarized app from Xcode's newest Foray archive. You can
#      also pass an app: scripts/make-dmg.sh /path/to/Foray.app
#
# Testing the installer itself without a notarized app:
#   scripts/make-dmg.sh --build     (builds and signs one locally; opens only on your own Macs)
set -euo pipefail
cd "${0:A:h}/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

if [[ ${1:-} == --build ]]; then
  identity="Apple Development"
  security find-identity -v -p codesigning | grep -q "Developer ID Application" && identity="Developer ID Application"
  RF_RELEASE=1 RF_UNIVERSAL=1 RF_SIGN_IDENTITY="$identity" scripts/bundle.sh release >/dev/null
  app=.build/Foray.app
  timestamp=--timestamp=none
  [[ $identity == "Developer ID Application" ]] && timestamp=--timestamp
  codesign --force --options runtime $timestamp --entitlements Resources/Foray.entitlements --sign "$identity" "$app"
elif [[ -n ${1:-} ]]; then
  app=${1%/}
else
  # Newest archive of the app (archive names contain odd spaces, so glob rather than type them).
  archive=$(ls -td ~/Library/Developer/Xcode/Archives/*/Foray*.xcarchive(N) 2>/dev/null | head -1)
  [[ -n $archive ]] || { print -u2 "No Foray archive in Xcode. Archive and distribute it first (see the top of this script)."; exit 1; }
  print "Exporting the notarized app from: ${archive:t}"
  xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$scratch/export" >/dev/null 2>&1 || {
    print -u2 "That archive isn't notarized yet. In Xcode's Organizer, use Distribute App › Direct Distribution and wait for \"Ready to distribute\"."
    exit 1
  }
  app="$scratch/export/Foray.app"
fi

[[ -d $app/Contents ]] || { print -u2 "error: $app isn't an app bundle"; exit 1; }
codesign --verify --strict "$app"
# The `foray` tool and the privileged helper must be inside, signed under the names the app and
# the helper check each other by.
id=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$app/Contents/Info.plist")
for pair in foray:$id.cli foray-helper:$id.helper; do
  tool="$app/Contents/Helpers/${pair%%:*}"
  [[ -x $tool ]] || { print -u2 "error: $tool is missing"; exit 1; }
  signed=$(codesign -dv "$tool" 2>&1 | sed -n 's/^Identifier=//p')
  [[ $signed == "${pair#*:}" ]] || { print -u2 "error: $tool is signed as \"$signed\", not \"${pair#*:}\""; exit 1; }
done
[[ -f "$app/Contents/Library/LaunchDaemons/$id.helper.plist" ]] || { print -u2 "error: the helper's launchd plist is missing"; exit 1; }
if xcrun stapler validate "$app" >/dev/null 2>&1; then
  spctl --assess --type execute "$app" && print "Notarized and accepted by Gatekeeper."
else
  print -u2 "warning: this app isn't notarized; other Macs will block it."
fi
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
volname="Foray $version"
mount="/Volumes/$volname"
if [[ -e $mount ]]; then
  # An earlier installer image with the same name (e.g. one opened to look at it): eject it.
  if hdiutil info | grep -qF "$mount"; then
    print "Ejecting the earlier \"$volname\" disk image."
    hdiutil detach "$mount" -quiet || hdiutil detach "$mount" -force -quiet
  else
    print -u2 "\"$mount\" is in use by something else; eject it first."
    exit 1
  fi
fi

# A writable image to lay out, then compressed.
megabytes=$(( $(du -sm "$app" | cut -f1) + 20 ))
hdiutil create -size ${megabytes}m -fs HFS+ -volname "$volname" -ov "$scratch/rw.dmg" >/dev/null
hdiutil attach -nobrowse -noverify -noautoopen -mountpoint "$mount" "$scratch/rw.dmg" >/dev/null
{
  ditto "$app" "$mount/Foray.app"
  ln -s /Applications "$mount/Applications"
  swift scripts/dmg-layout.swift "$mount" Resources/Foray.icns
  SetFile -a C "$mount"            # show .VolumeIcon.icns as the disk's icon
  rm -rf "$mount/.fseventsd"   # (detaching flushes the volume; no global sync, which can hang)
} always {
  hdiutil detach "$mount" -quiet || hdiutil detach "$mount" -force -quiet
}
mkdir -p dist
dmg="dist/Foray-$version.dmg"
rm -f "$dmg"
hdiutil convert "$scratch/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg" >/dev/null
# The app inside carries the notarization; sign the disk image too when a Developer ID key is here.
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  codesign --force --timestamp --sign "Developer ID Application" "$dmg"
fi
echo "$dmg"
