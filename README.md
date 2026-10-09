<p align="center"><img src="Resources/Icon/Foray-1024.png" width="160" alt="Foray icon"></p>

# Foray

A file browser for macOS that does what Finder does, minus the parts that get in the way.

- **Search starts where you are.** ⌘F searches the current folder and its subfolders, by name, not the whole Mac by contents. Filter with plain words: `kind:images size:>5MB modified:<7d`. Finds files Spotlight hasn't indexed, too.
- **Sort order survives view changes.** Icon, list, column and gallery views share one sort, so switching views never reshuffles your files.
- **Search by kind:** documents, images, video, audio, programs, archives, code, PDFs, fonts.
- **Everything else you use Finder for:** tabs, sidebar, Quick Look, tags, Get Info, copy and move with undo, Trash with Put Back, aliases, compress, smart folders, iCloud Drive and Dropbox-style folders, network servers, AirDrop and Share.
- **Plus:** batch rename with regular expressions and a preview, Recents, an Inspector, folder sizes in list view, `foray://` links, and a built-in guide (⌘?).

Foray runs alongside Finder; it doesn't replace the desktop or change any system settings.

## Install

1. Download the latest `Foray-x.y.z.dmg` from [Releases](../../releases).
2. Open it and drag **Foray** to **Applications**.
3. Open Foray. macOS asks before it can see Desktop, Documents, Downloads and external drives; allow those. For the Trash, Mail data and other protected places, add Foray in **System Settings › Privacy & Security › Full Disk Access** (Foray › Settings › Privacy has a button for it).

Requires macOS 26 or later (Apple silicon or Intel).

## Build from source

Requires Xcode 27 (Swift 6.4).

```sh
scripts/bundle.sh release && open ".build/Foray Dev.app"   # build and run a test copy
swift test                                                  # run the tests
```

Test builds are a separate app, **Foray Dev** (its own bundle ID, settings and privacy grants, and a DEV badge on the icon), so they never get mixed up with an installed Foray. They're signed with your Apple Development certificate when you have one, which keeps permissions like Full Disk Access across rebuilds.

Releases are built from `Xcode/Foray.xcodeproj` (scheme "Foray App"): Product › Archive, then Distribute App › Direct Distribution signs with Developer ID and notarizes. `scripts/make-dmg.sh <exported Foray.app>` turns the result into the DMG.

`DESIGN.md` describes the architecture, and the in-app guide (`Sources/RFUI/Guide/guide.html`) describes every feature.

## License

MIT. See [LICENSE](LICENSE).

Foray is an independent project and is not affiliated with or endorsed by Apple. Finder is a trademark of Apple Inc.
