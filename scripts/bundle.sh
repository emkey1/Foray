#!/bin/zsh
# Builds RealFinder and wraps it in an .app bundle (ad-hoc signed) at .build/RealFinder.app.
#   scripts/bundle.sh [debug|release]   (default: debug)
#   scripts/bundle.sh release && open .build/RealFinder.app
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
codesign --force --sign - --timestamp=none "$app" >/dev/null
echo "$app"
