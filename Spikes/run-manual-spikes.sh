#!/bin/zsh
# Spikes that need permissions the build session doesn't have. Run from a terminal app that has
# Full Disk Access (System Settings › Privacy & Security › Full Disk Access) and paste the output
# into Spikes/results/manual.txt.
#
#   S4  Put Back: trashes ONE scratch file it creates, inspects the Trash, then deletes that file.
#   S6  Comments: writes a Spotlight comment xattr on a scratch file, then asks Finder (Apple Events;
#       macOS will ask once to allow your terminal to control Finder) what comment it sees.
#   S7  Cloud thumbnails: finds ONE small not-downloaded iCloud Drive file and requests a thumbnail.
#       If thumbnails force downloads, that file (only) gets downloaded.
set -u
cd "${0:A:h}"
swift build -c release >/dev/null || exit 1
mkdir -p fixtures results
FIX="$PWD/fixtures"

echo "=== S4 Put Back"
.build/release/trash-spike "$FIX"

echo "\n=== S6 Comments"
f="$FIX/rf-comment-spike.txt"; echo comment > "$f"
python3 - "$f" <<'EOF'
import plistlib, subprocess, sys
path = sys.argv[1]
data = plistlib.dumps("written by xattr", fmt=plistlib.FMT_BINARY)
subprocess.run(["xattr", "-wx", "com.apple.metadata:kMDItemFinderComment", data.hex(), path], check=True)
EOF
echo "xattr comment: $(xattr -p com.apple.metadata:kMDItemFinderComment "$f" 2>/dev/null | head -c 80)"
echo "Finder sees:   '$(osascript -e "tell application \"Finder\" to get comment of (POSIX file \"$f\" as alias)" 2>&1)'"
osascript -e "tell application \"Finder\" to set comment of (POSIX file \"$f\" as alias) to \"written by Finder\"" 2>&1
sleep 1
echo "after Finder write, xattr: $(xattr -p com.apple.metadata:kMDItemFinderComment "$f" 2>/dev/null | head -c 80)"
rm -f "$f"

echo "\n=== S7 Cloud thumbnails"
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
cand=$(python3 - "$ICLOUD" <<'EOF2'
import os, stat, sys
for root, dirs, files in os.walk(sys.argv[1]):
    for n in files:
        p = os.path.join(root, n)
        st = os.lstat(p)
        if st.st_flags & 0x40000000 and st.st_size < 2_000_000:   # SF_DATALESS, small
            print(p); sys.exit()
EOF2
)
if [[ -z "$cand" ]]; then
  echo "no dataless iCloud Drive file found (everything is downloaded) — skipped"
else
  .build/release/thumb-spike "$cand"
fi
