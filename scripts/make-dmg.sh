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
# Ejects a disk image by mount point or device.
eject() {
  diskutil eject "$1" >/dev/null 2>&1 && return
  diskutil unmountDisk force "$1" >/dev/null 2>&1
  diskutil eject "$1" >/dev/null 2>&1 || true
}

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
# An archive made before the version was bumped carries the last release's number: making it would
# overwrite that release's installer in dist/. Stop instead (RF_DMG_DIR builds elsewhere, for tests).
source_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
if [[ -z ${RF_DMG_DIR:-} && $version != "$source_version" ]]; then
  print -u2 "error: this app is version $version, but Resources/Info.plist says $source_version."
  print -u2 "The archive was probably made before the version was bumped: archive again in Xcode, then rerun this."
  exit 1
fi
if [[ -z ${RF_DMG_DIR:-} ]] && command -v gh >/dev/null && gh release view "v$version" >/dev/null 2>&1; then
  print -u2 "error: AOK-Foray $version is already released on GitHub; not replacing its installer."
  exit 1
fi
volname="AOK-Foray $version"
mount="/Volumes/$volname"
if [[ -e $mount ]]; then
  # An earlier installer image with the same name (e.g. one opened to look at it): eject it.
  if diskutil info "$mount" 2>/dev/null | grep -q "Disk Image"; then
    print "Ejecting the earlier \"$volname\" disk image."
    eject "$mount"
  else
    print -u2 "\"$mount\" is in use by something else; eject it first."
    exit 1
  fi
fi

# A writable image to lay out, then compressed. The volume is HFS+ (Mac OS Extended): the window
# layout's record of where the background picture is (scripts/dmg-layout.swift) is written for it.
# `diskutil image`, which replaces the deprecated hdiutil verbs, only makes APFS volumes itself,
# so the image starts with no filesystem and newfs_hfs formats it.
megabytes=$(( $(du -sm "$app" | cut -f1) + 20 ))
diskutil image create blank --fs None --format RAW --size ${megabytes}m "$scratch/rw.dmg" >/dev/null
device=$(diskutil image attach --noMount "$scratch/rw.dmg" | awk 'NR == 1 { print $1 }')
[[ $device == /dev/disk* ]] || { print -u2 "error: couldn't attach the new disk image"; exit 1; }
newfs_hfs -v "$volname" "$device" >/dev/null
eject "$device"
# --nobrowse: it doesn't appear in Finder or on the desktop while it's being laid out.
diskutil image attach --nobrowse --mountPoint "$mount" "$scratch/rw.dmg" >/dev/null
{
  ditto "$app" "$mount/Foray.app"
  ln -s /Applications "$mount/Applications"
  swift scripts/dmg-layout.swift "$mount" Resources/Foray.icns
  SetFile -a C "$mount"            # show .VolumeIcon.icns as the disk's icon
  rm -rf "$mount/.fseventsd"   # (detaching flushes the volume; no global sync, which can hang)
} always {
  eject "$mount"
}
# RF_DMG_DIR: somewhere other than dist/ (for trying the script without touching a released file).
out=${RF_DMG_DIR:-dist}
mkdir -p "$out"
dmg="$out/Foray-$version.dmg"
rm -f "$dmg"
# (It reports progress on stderr; keep that out of the way unless it fails.)
diskutil image create from --format UDZO "$scratch/rw.dmg" "$dmg" >/dev/null 2>"$scratch/compress.log" || { cat "$scratch/compress.log" >&2; exit 1; }
# The app inside carries the notarization; sign the disk image too when a Developer ID key is here.
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  codesign --force --timestamp --sign "Developer ID Application" "$dmg"
fi
# The same installer named plainly, for the permanent "latest" link
# (https://github.com/emkey1/Foray/releases/latest/download/Foray.dmg): attach both to the release.
cp -f "$dmg" "$out/Foray.dmg"
echo "$dmg"
echo "$out/Foray.dmg (the same file, for the latest-version link)"
