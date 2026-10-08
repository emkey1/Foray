#!/bin/zsh
# Builds RealFinder and wraps it in an .app bundle at .build/RealFinder.app.
#   scripts/bundle.sh [debug|release]   (default: debug)
#   scripts/bundle.sh release && open .build/RealFinder.app
# Signing: ad hoc by default. macOS ties privacy grants (Full Disk Access, Automation) to an
# ad-hoc build's exact contents, so every rebuild loses them. Set RF_SIGN_IDENTITY to a
# code-signing identity (e.g. "Apple Development") to keep grants across rebuilds:
#   RF_SIGN_IDENTITY="Apple Development" scripts/bundle.sh release
set -euo pipefail
cd "${0:A:h}/.."
config=${1:-debug}
swift build -c "$config" --product RealFinder
bin=$(swift build -c "$config" --show-bin-path)/RealFinder
app=.build/RealFinder.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/RealFinder"
# SwiftPM resource bundles (e.g. the user guide); Bundle.module finds them in Contents/Resources.
for b in "${bin:h}"/*.bundle(N); do cp -R "$b" "$app/Contents/Resources/"; done
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign "${RF_SIGN_IDENTITY:--}" --timestamp=none "$app" >/dev/null
echo "$app"
