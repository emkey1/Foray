#!/bin/zsh
# Takes screenshots that are safe to publish, into Screenshots/ (or the folder you name):
#   scripts/screenshots.sh [folder]
# They're the real app's windows showing invented files on a temporary disk image called "Atlas",
# with a stand-in sidebar, so nothing from this Mac appears in them (no user name, disks, network
# computers or tags). A debug build of Foray Dev comes to the front for about a minute, showing
# and photographing one window after another, then quits. Leave the Mac alone while it runs.
# The pictures are set up in Sources/RFUI/ScreenshotStudio.swift (debug builds only).
# Needs Screen Recording permission for the terminal you run it from.
set -euo pipefail
cd "${0:A:h}/.."
out=${1:-Screenshots}
mkdir -p "$out"
out=${out:A}
scratch=$(mktemp -d)
mount=/Volumes/Atlas
[[ -e $mount ]] && { print -u2 "$mount already exists; eject it first."; exit 1; }
cleanup() { hdiutil detach "$mount" -quiet 2>/dev/null || hdiutil detach "$mount" -force -quiet 2>/dev/null || true; rm -rf "$scratch"; }
trap cleanup EXIT
scripts/bundle.sh debug >/dev/null
hdiutil create -size 300m -fs APFS -volname Atlas "$scratch/atlas.dmg" -quiet
# -nobrowse: the disk doesn't show up in Finder or on the desktop while this runs.
hdiutil attach "$scratch/atlas.dmg" -nobrowse -quiet
rm -f "$out/.request" "$out/.done"
# -n: a separate copy, even if Foray Dev is open.
open -n ".build/Foray Dev.app" --env RF_SCREENSHOTS="$out" --env RF_DEMO_ROOT="$mount" --stderr "$scratch/log"
# The app sets up each window and asks for its picture by writing "<window number> <file name>"
# to .request; taking it here means the permission needed is this terminal's Screen Recording.
for ((i = 0; i < 1500; i++)); do
  [[ -e $out/.done ]] && break
  if [[ -s $out/.request ]]; then
    read -r window name < "$out/.request" || true   # (no newline at the end of the file)
    screencapture -x -l"$window" "$out/$name" || print -u2 "Couldn't capture $name (does this terminal have Screen Recording permission?)"
    rm -f "$out/.request"
  fi
  sleep 0.1 2>/dev/null || /bin/sleep 0.1
done
[[ -e $out/.done ]] || { print -u2 "Foray Dev didn't finish; some pictures may be missing."; tail -5 "$scratch/log" >&2 2>/dev/null || true; }
rm -f "$out/.request" "$out/.done"
print "Screenshots are in $out"
ls "$out"
