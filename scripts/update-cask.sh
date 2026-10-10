#!/bin/zsh
# After publishing a GitHub release: points the Homebrew cask (github.com/emkey1/homebrew-tap,
# Casks/foray.rb) at it.
#   scripts/update-cask.sh            (version from Resources/Info.plist, DMG from dist/)
#   scripts/update-cask.sh 0.9.2
# Users then get it with `brew upgrade --cask foray` (Foray also updates itself).
set -euo pipefail
cd "${0:A:h}/.."
version=${1:-$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)}
dmg="dist/Foray-$version.dmg"
[[ -f $dmg ]] || { print -u2 "No $dmg. Make it with scripts/make-dmg.sh first."; exit 1; }
# The cask must match what people download: check the published asset is this file.
url="https://github.com/emkey1/Foray/releases/download/v$version/Foray-$version.dmg"
local_sum=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
remote_sum=$(curl -fsSL "$url" | shasum -a 256 | cut -d' ' -f1) || { print -u2 "Release v$version isn't published yet ($url)."; exit 1; }
[[ $local_sum == "$remote_sum" ]] || { print -u2 "The published DMG differs from $dmg; not updating the cask."; exit 1; }

tap=$(mktemp -d)
trap 'rm -rf "$tap"' EXIT
gh repo clone emkey1/homebrew-tap "$tap" -- -q
cask="$tap/Casks/foray.rb"
sed -i '' -E "s/^  version \".*\"/  version \"$version\"/; s/^  sha256 \".*\"/  sha256 \"$local_sum\"/" "$cask"
# From 0.9.3 the app contains the `foray` command-line tool: have Homebrew link it into its bin.
if ! grep -q 'Contents/Helpers/foray' "$cask"; then
  sed -i '' -E 's|^  app "Foray.app"$|  app "Foray.app"\
  binary "#{appdir}/Foray.app/Contents/Helpers/foray"|' "$cask"
fi
if git -C "$tap" diff --quiet; then
  print "The cask is already at $version."
  exit 0
fi
command -v brew >/dev/null && brew style "$cask" >/dev/null
git -C "$tap" commit -qam "Foray $version"
git -C "$tap" push -q
print "Cask updated to $version: brew upgrade --cask foray"
