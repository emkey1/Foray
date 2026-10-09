#!/bin/zsh
# Builds a test copy of the app at ".build/Foray Dev.app":
#   scripts/bundle.sh [debug|release]   (default: debug)
#   open ".build/Foray Dev.app"
# "Foray Dev" has its own bundle ID (io.github.emkey1.Foray.dev), name, icon badge, settings
# folder and privacy grants, so it never gets mixed up with the Foray installed in Applications.
#
# RF_RELEASE=1 builds the real Foray (.build/Foray.app) instead; make-dmg.sh does this.
# RF_UNIVERSAL=1 builds for Apple silicon and Intel (make-dmg.sh does this too).
# Signing: your "Apple Development" certificate if you have one (privacy grants such as Full Disk
# Access then survive rebuilds), otherwise ad hoc. RF_SIGN_IDENTITY overrides.
set -euo pipefail
cd "${0:A:h}/.."
config=${1:-debug}
arch=()
[[ -n ${RF_UNIVERSAL:-} ]] && arch=(--arch arm64 --arch x86_64)
swift build -c "$config" $arch --product Foray
bin=$(swift build -c "$config" $arch --show-bin-path)/Foray

if [[ -n ${RF_RELEASE:-} ]]; then
  app=.build/Foray.app; name=Foray; id=io.github.emkey1.Foray; scheme=foray; icon=Foray.icns
else
  app=".build/Foray Dev.app"; name="Foray Dev"; id=io.github.emkey1.Foray.dev; scheme=foray-dev; icon=Foray-Dev.icns
fi
identity=${RF_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  identity=-
  security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development" && identity="Apple Development"
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Foray"
# SwiftPM resource bundles (e.g. the user guide); Bundle.module finds them in Contents/Resources.
for b in "${bin:h}"/Foray_*.bundle(N); do cp -R "$b" "$app/Contents/Resources/"; done
plist="$app/Contents/Info.plist"
cp Resources/Info.plist "$plist"
cp "Resources/$icon" "$app/Contents/Resources/Foray.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" -c "Set :CFBundleName $name" -c "Set :CFBundleDisplayName $name" \
  -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $scheme" "$plist"
codesign --force --sign "$identity" --timestamp=none "$app" >/dev/null
echo "$app"
