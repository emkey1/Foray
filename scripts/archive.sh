#!/bin/zsh
# Archives AOK-Foray and sends it to Apple to be notarized, from the command line: the same as Xcode's
# Product › Archive (Xcode/Foray.xcodeproj, "Foray App" scheme) and then Organizer › Distribute App ›
# Direct Distribution. Signing uses the developer account signed in to Xcode (Developer ID, team
# UYU5FM4LQ4), so nothing has to be in the keychain. Apple takes a few minutes; then scripts/make-dmg.sh
# exports the notarized app from this archive and makes the installer.
#   scripts/archive.sh               archive, and send it to Apple
#   scripts/archive.sh --no-upload   only archive, into a throwaway folder (to check it builds and signs;
#                                    Xcode's Organizer and make-dmg.sh never see it)
set -euo pipefail
cd "${0:A:h}/.."
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
if [[ ${1:-} == --no-upload ]]; then
  archive="$scratch/Foray $version.xcarchive"
else
  # (make-dmg.sh exports from the newest Foray*.xcarchive here.)
  archive=~/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/"Foray $version $(date +%H.%M.%S).xcarchive"
fi
print "Archiving AOK-Foray $version…"
xcodebuild -project Xcode/Foray.xcodeproj -scheme "Foray App" -configuration Release -destination "generic/platform=macOS" \
  -archivePath "$archive" -allowProvisioningUpdates archive >"$scratch/archive.log" 2>&1 || { tail -30 "$scratch/archive.log" >&2; exit 1; }
if [[ ${1:-} == --no-upload ]]; then
  app=$(ls -d "$archive"/Products/Applications/*.app(N) | head -1)
  # (An archive is signed for development; sending it re-signs it with Developer ID.)
  print "Archived (not sent): ${app:t}, signed by $(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  exit 0
fi
cat > "$scratch/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>UYU5FM4LQ4</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
print "Sending it to Apple to be notarized…"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$scratch/ExportOptions.plist" \
  -exportPath "$scratch/export" -allowProvisioningUpdates >"$scratch/export.log" 2>&1 || { tail -30 "$scratch/export.log" >&2; exit 1; }
print "Sent: $archive"
print "When Apple has notarized it (usually a few minutes), run scripts/make-dmg.sh."
