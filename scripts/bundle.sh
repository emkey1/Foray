#!/bin/zsh
# Builds Foray and wraps it in an .app bundle at .build/Foray.app.
#   scripts/bundle.sh [debug|release]   (default: debug)
#   scripts/bundle.sh release && open .build/Foray.app
# Signing: ad hoc by default. macOS ties privacy grants (Full Disk Access, Automation) to an
# ad-hoc build's exact contents, so every rebuild loses them. Set RF_SIGN_IDENTITY to a
# code-signing identity (e.g. "Apple Development") to keep grants across rebuilds:
#   RF_SIGN_IDENTITY="Apple Development" scripts/bundle.sh release
# RF_UNIVERSAL=1 builds for Apple silicon and Intel (make-dmg.sh does this).
set -euo pipefail
cd "${0:A:h}/.."
config=${1:-debug}
arch=()
[[ -n ${RF_UNIVERSAL:-} ]] && arch=(--arch arm64 --arch x86_64)
swift build -c "$config" $arch --product Foray
bin=$(swift build -c "$config" $arch --show-bin-path)/Foray
app=.build/Foray.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Foray"
# SwiftPM resource bundles (e.g. the user guide); Bundle.module finds them in Contents/Resources.
for b in "${bin:h}"/Foray_*.bundle(N); do cp -R "$b" "$app/Contents/Resources/"; done
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/Foray.icns "$app/Contents/Resources/Foray.icns"
codesign --force --sign "${RF_SIGN_IDENTITY:--}" --timestamp=none "$app" >/dev/null
echo "$app"
