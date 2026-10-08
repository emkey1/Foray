# RealFinder: Design Document

| | |
|---|---|
| Status | Draft v0.6: M0 results folded in (`Spikes/RESULTS.md`); M1–M3 complete; M4 built (awaits its week of daily use); M5 under way |
| Date | 2026-10-08 |
| Toolchain baseline | Xcode 27, Swift 6.4, developed on macOS 26.6 |
| Working name | RealFinder (see Q9) |

---

## 1. Summary

RealFinder is a native macOS file manager meant to replace Finder for everyday browsing and file management. It aims for full Finder parity and fixes some long-standing Finder annoyances. Three behaviors define the project:

1. **Search defaults to the current tab's folder**, not "This Mac".
2. **Searches and folder listings can be limited to file categories** (Images, Documents, Programs, Archives, Code and others), and users can define their own categories.
3. **Sort order belongs to the folder, not to the view mode.** Switching between icon, list, column and gallery views never changes the order.

Everything else Finder does is also in scope and is phased in (§4): tabs, sidebar, Quick Look, tags, Get Info, file operations with undo, drag and drop, network volumes and iCloud. Finder keeps running alongside RealFinder because it owns the desktop. RealFinder can optionally become the system's default file viewer.

---

## 2. Goals and non-goals

### Goals

- **G1. Finder parity** for browsing and file management (§4). A user should never need to go back to Finder for a routine task.
- **G2. The three headline behaviors** (§3.1–§3.3).
- **G3. Never block on the filesystem.** Slow, hung or disconnected volumes never cause a spinning cursor.
- **G4. Predictable state.** View settings, sort order and search scope follow documented rules. There is no hidden per-folder state.
- **G5. Finder muscle memory by default.** Menu layout, keyboard shortcuts and drag modifiers match Finder. Any difference is opt-in or purely additive.
- **G6. Safe file operations.** Errors are handled per item. A partially copied file never appears under its real name. The operation journal survives crashes, and operations can be undone.

### Non-goals (v1)

- **Drawing the desktop.** Finder keeps showing desktop icons and Stacks (Q3).
- **Replacing or killing the Finder process.**
- **Hosting Finder Sync extensions.** Dropbox and Box context menus and badges are delivered only to Finder, and no public API exposes them to other apps.
- **Mac App Store distribution.** A general file manager can't work inside the App Sandbox.
- **Features without public APIs, or removed from macOS:** the "Enter Time Machine" UI, CD/DVD burning, and the AirDrop discovery window.
- **Reading or writing `.DS_Store` view settings.**

---

## 3. Headline features

### 3.1 Search scoped to the current folder

**The Finder problem.** Finder searches "This Mac" by default. The option to search the current folder is buried in Settings › Advanced. Finder also matches file names *and* contents by default, which floods the results. It relies only on Spotlight, so it misses hidden files, unindexed drives and most network shares. Restricting results by type means adding a "Kind" criteria row every time.

**Behavior**

- Pressing Cmd-F, or clicking or typing in the toolbar search field, searches the current tab's location **including subfolders**. This is the default. Settings › Search also offers "This Mac" or "Last used scope".
- During a search, a scope bar appears below the toolbar:

  ```
  Search: [ Projects v ] [ This Mac ]   [x] Subfolders   Match: [ Names v ]  | All  Folders  Documents  Images  Audio  Video  Programs  Archives  Code  + |
  ```

- Unchecking **Subfolders** turns the search into a live filter of the current folder only. The results view is the same, and the results are instant.
- Results stream in as each backend reports them (§5.6). They update live as files change.
- Pressing Escape, or clearing the field, ends the search and restores the folder with its previous selection and scroll position. Each search is a history entry, so Back also returns to the folder.
- Each tab has its own independent search.

**What "current folder" means**

| What the tab is showing | Default scope |
|---|---|
| A folder in icon, list or gallery view | That folder (even when list rows are expanded and the selection is inside a subfolder) |
| A folder in column view | The folder shown in the path bar: the column with keyboard focus, not the deepest column |
| Search results | The active search is refined (same scope) |
| Recents, a tag, or a smart folder | Filter within that set of items |
| Trash | All trash folders |
| Computer or Network | This Mac |

A context-menu command, **Search in "‹folder›"**, starts a search scoped to a selected subfolder.

**Matching**

- The default match is **Names**. Matching ignores case and diacritics and uses Unicode-normalized names. Terms separated by spaces must all match. `*` and `?` wildcards work, and `/regex/` is opt-in.
- **Names & Contents** is one click away, and the app remembers the choice. Names is the default because content matching floods results with documents that merely mention the word.
- Power users can type tokens directly in the field. Changes made in the scope bar are written back as tokens, so the field always shows the full query.

| Token | Example | Meaning |
|---|---|---|
| `kind:` | `kind:image`, `kind:image,video` | Category (§3.2) |
| `ext:` | `ext:heic` | Filename extension |
| `type:` | `type:public.svg-image` | UTType conformance |
| `size:` | `size:>100MB`, `size:1MB..5MB` | Logical size |
| `modified:` `created:` `added:` `opened:` | `modified:<7d`, `created:2025` | Date ranges |
| `tag:` | `tag:red`, `tag:"Tax 2025"` | Finder tags |
| `content:` | `content:"invoice 2291"` | Contents (Spotlight only) |
| `hidden:` | `hidden:yes` | Include hidden items |
| `-` prefix | `-ext:tmp` | Negation |
| `OR` | `kind:image OR kind:video` | Either condition |

- In P2, an advanced criteria editor adds rows like Finder's "+" rows. Saved searches become smart folders.

**Query model** (RFModel)

```swift
struct SearchQuery: Codable, Hashable, Sendable {
    var text: String                    // raw field text, including tokens
    var terms: [SearchTerm]             // parsed name terms + tokens
    var match: MatchMode                // .names, .namesAndContents
    var scope: SearchScope
    var kinds: Set<KindCategory.ID>     // OR'd; empty = any kind
    var includeHidden = false
    var includePackageContents = false
}

enum SearchScope: Codable, Hashable, Sendable {
    case folder(URL, recursive: Bool)
    case thisMac
    case volumes([URL])
    case itemSet(Location)              // Recents, tag, smart folder, Trash
}
```

**Results.** Search results are an ordinary location (`.search(SearchQuery)`). The same views and the same arrangement model (§3.3) display them. They use the "Search Results" settings class. By default that is list view with a **Where** column that shows each item's path relative to the scope folder. Sorting and grouping work as they do for folders, so you can group results by Kind or by parent folder.

### 3.2 File-type categories ("kinds")

**The Finder problem.** Finder can restrict by kind only through criteria rows or through `kind:` syntax that you have to remember. Its list of kinds is fixed, so there is no "RAW photos" or "Code", and you can't filter an ordinary folder listing by kind.

**Model.** A kind category is a named rule set that users can edit:

```swift
struct KindCategory: Codable, Identifiable, Sendable {
    let id: ID
    var name: String
    var symbol: String                  // SF Symbol
    var conformsTo: [UTType]            // any-of; hierarchy-aware conformance
    var extensions: [String]            // any-of; for types the system doesn't know
    var alsoMatching: ItemPredicate?    // any-of; e.g. "regular file with executable bit"
    var excluding: [UTType]             // carve-outs, applied last
}
```

An item matches a category if it matches any of `conformsTo`, `extensions` or `alsoMatching`, and doesn't conform to anything in `excluding`.

**Built-in categories** (editable and resettable; validated in M0 against real system types, see `Spikes/RESULTS.md`):

| Category | Conforms to (examples) | Notes |
|---|---|---|
| Folders | `public.folder` | Excludes packages |
| Documents | `com.adobe.pdf`, `public.rtf`, `public.plain-text`, `net.daringfireball.markdown`, `public.spreadsheet`, `public.presentation`, Word/Excel/PowerPoint, iWork, `org.idpf.epub-container` | Excludes `public.source-code` and `public.script`, because plain text is a supertype of code |
| Images | `public.image` | Includes RAW (`public.camera-raw-image`) and SVG |
| Video | `public.movie` | Plus extensions `mkv`, `webm`, `flv` (dynamic types unless a player app declares them) |
| Audio | `public.audio` | |
| Programs | `com.apple.application`, `public.unix-executable` | Also any regular file with the executable bit set. Not `public.script` or `public.executable`: `.js` conforms to both, so scripts count only when they're executable |
| Archives | `public.archive`, `com.apple.disk-image` | Plus extensions `7z`, `rar`, `xz`, `zst` |
| Code | `public.source-code`, `public.script`, `public.json`, `public.yaml`, `public.xml`, `com.apple.property-list` | Excludes `public.image` (SVG conforms to `public.xml`). Plus extensions for languages without system types (`rs`, `go`, `ts`…). `.ts` also matches Video, because the system maps it to MPEG-2 transport stream; this is accepted |
| PDFs | `com.adobe.pdf` | |
| Fonts | `public.font` | Plus extensions `woff`, `woff2` |

**Where categories apply**

- **Search scope bar chips.** Selecting several chips matches any of them.
- **Folder filter.** The same chips work on any folder, outside of search, through View › Filter by Kind or the filter button. For example, "show only images in this folder". The filter is stored in the `Arrangement` (§3.3), so it persists the same way the sort order does.
- **The `kind:` token.**

**Matching in each backend**

- **Crawl and folder filter.** The type is derived from the filename extension during enumeration (memoized; see §5.4) and checked with `UTType.conforms(to:)`. Every category needs an extension list as well as conformance, because unknown extensions resolve to dynamic types that conform to nothing useful. Results are memoized per UTType, so the cost per item is one dictionary lookup.
- **Spotlight.** Conformance rules become `kMDItemContentTypeTree == "<uti>"`, combined with OR. Extension rules use `kMDItemFSName`, and exclusions are negated terms. Rules that Spotlight can't express, such as the executable bit, are applied as a post-filter on our own `stat`.

### 3.3 One arrangement, many views (sort order survives view changes)

**The Finder problem.** Finder keeps a separate sort setting for each view mode. In list view, items sort by the clicked column header. Icon and gallery views use "Sort By" in View Options, which includes "None" and grid snapping. Column view has its own setting. Per-folder `.DS_Store` state and "Use as Defaults" add to the confusion. As a result, switching from list to icon view routinely shows a different order, or no order at all.

**Design.** Each location's view state is split into two independent parts:

```swift
/// Which items are shown and in what order. Independent of view mode.
struct Arrangement: Codable, Hashable, Sendable {
    var sort: [SortDescriptor]          // primary first; name, then FileID, are implicit final tiebreakers
    var groupBy: GroupKey?              // nil = no groups
    var foldersFirst: Bool
    var showHidden: Bool
    var kindFilter: Set<KindCategory.ID>
}

struct SortDescriptor: Codable, Hashable, Sendable {
    var key: SortKey    // .name .kind .size .dateModified .dateCreated .dateAdded
                        // .dateLastOpened .tags .extension .version .comments .manual
    var ascending: Bool
}

/// How items are drawn. Options for every mode are kept, so switching back restores them.
struct Presentation: Codable, Hashable, Sendable {
    var mode: ViewMode                  // .icon .list .column .gallery
    var icon: IconOptions               // size, grid spacing, label position, text size, item info, previews
    var list: ListOptions               // visible columns, order, widths; relative dates; calculate sizes
    var column: ColumnOptions           // column width, preview column, icons
    var gallery: GalleryOptions         // thumbnail size, metadata, Quick Actions
    var previewPaneVisible: Bool
}
```

**Rules**

1. **Changing `Presentation.mode` never changes `Arrangement`.** Every view receives the same `ItemSnapshot`, which is already filtered, sorted and grouped (§5.3). A mode switch is a re-render, not a reload or a re-sort.
2. **Selection and the focus anchor belong to the tab, not the view.** The focus anchor is the item that has keyboard focus. Both survive mode switches, and the new view scrolls the anchor into view.
3. **Every mode edits the same `Arrangement`.** List column headers, the toolbar Sort/Group menu, View › Sort By and the column-view header menu all write to `arrangement.sort`.
4. **Clicking a list column header sets the primary sort key.** Clicking it again reverses the direction. Shift-clicking adds or toggles a secondary key, which Finder doesn't support.
5. **The sort key stays visible in list view.** If the primary sort key has no visible column, the header shows a chip such as **"Sorted by Date Added ↓"** instead of quietly switching to another column. For example, this happens if you sort by Date Added in icon view and then switch to list view. A setting can show the missing column automatically instead.
6. **Column view applies the arrangement to every column.**
7. **Grouping is independent of sorting.** When items are grouped, the sort applies within each group. The group key determines the order of the groups (for example Today, Yesterday, Previous 7 Days…).
8. **Manual arrangement is `SortKey.manual`.** This is Finder's "None" sort with free icon positions in icon view. Other modes order items by the reading order of the stored icon positions (top to bottom, left to right), so even a manual order survives a mode switch. New items are added at the end.
9. **Missing values sort last** in both directions. Examples are folder sizes that aren't computed yet and items that were never opened. When background values arrive, re-sorting is debounced and keeps the selection and focus anchor visually stable.
10. **Each sort key has a fixed comparator.** Names use `localizedStandardCompare`, which gives Finder's natural, locale-aware order ("file 2" before "file 10"). Kinds compare their localized kind strings. Dates and sizes compare numerically.

**Which settings apply to a location**

```
effective = folderOverride[location]        // only if the user pinned settings to this folder
         ?? classDefault[locationClass]     // Folder, Search Results, Recents, Trash, Volume root, Network, Tag
         ?? builtInDefault
```

- **Default model: "Same settings everywhere".** Changing the sort or view mode updates the default for that class of location (for example, all folders). A folder gets its own settings only when the user chooses **View › Remember Settings for This Folder**. A pin indicator in the path bar shows when this is on, and **Forget** removes it.
- **Alternative model: "Remember settings per folder"** (in Settings › Views). Any change creates a per-folder override. This works like Finder, but the settings are stored predictably in our database instead of `.DS_Store`.
- Per-folder overrides are keyed by volume UUID plus file ID, so they survive renames and moves. The path is kept as a fallback.
- Open tabs that use the same settings record update live.

### 3.4 Other proposed improvements (confirm or cut)

Each of these is additive or controlled by a setting, so Finder habits keep working.

| # | Improvement | Default |
|---|---|---|
| I1 | **Cut and paste.** Cmd-X marks items (shown dimmed), and Cmd-V moves them. Finder only offers Cmd-C followed by Cmd-Opt-V. | On |
| I2 | **Editable path.** Cmd-Shift-G, or clicking the path bar, turns the path bar into an address field with Tab completion and `~` expansion. Finder uses a modal sheet. | On |
| I3 | **Copies that don't abort.** An unreadable file is logged and skipped, the rest of the copy finishes, and you can retry the failures at the end. Copies can be paused and resumed, and conflicts follow an explicit policy (§5.7). | On |
| I4 | **Search finds what Spotlight misses:** hidden files, unindexed volumes and network shares, via the crawl backend. | On |
| I5 | **The status bar shows selection count and total size.** Folder sizes are calculated in the background, cached, and shown in every view. | On (sizes: setting) |
| I6 | **Hidden-files visibility is part of the arrangement**, so it follows the settings model (§3.3) instead of being one global switch. | On |
| I7 | **New File** in the File and context menus creates an empty text file, or a file from a user template in `~/Library/Application Support/RealFinder/Templates`. | On |
| I8 | **Copy As** copies the path, a `~`-relative path, a file URL, the name, or a shell-escaped path. **Open in Terminal** uses Terminal or a terminal the user chooses. | On |
| I9 | **Batch rename** supports regex, case changes and sequence numbers, with a live preview. The whole rename is undone in one step. | On |
| I10 | **Never writes `.DS_Store` files**, notably on network and USB volumes. | Always |
| I11 | **Return key** renames (as in Finder) or opens, depending on a setting. | Rename |
| I12 | **Dual-pane mode** shows two browsers side by side in one window, with copy and move to the other pane. | P3, off |

---

## 4. Finder parity inventory

**Phases:** P1 = daily-driver MVP · P2 = full parity · P3 = advanced or privileged · ✗ = not planned (reason given)

### 4.1 Windows and navigation

| Feature | Approach | Phase |
|---|---|---|
| Multiple windows; native tabs (merge, drag out, Show All Tabs) | NSWindow tabbing; one window controller per tab | P1 |
| Sidebar: Favorites, iCloud, Locations, Tags; add, remove and reorder items; eject buttons | NSOutlineView source list; items stored as bookmarks | P1 |
| Toolbar; toolbar customization | NSToolbar | P1 / P2 |
| Show and hide the path bar, status bar, preview pane, tab bar and sidebar | | P1 |
| Back and forward per tab; Enclosing Folder; Go menu locations; Recent Folders | | P1 |
| Go to Folder | Inline address field (I2) | P1 |
| Type-to-select | | P1 |
| Show/hide hidden files (Cmd-Shift-.) | `Arrangement.showHidden` | P1 |
| Show Package Contents | | P1 |
| Window and tab state restored after relaunch | `NSWindowRestoration` + tab state | P1 |
| Spring-loaded folders and tabs | `NSSpringLoadingDestination` | P2 |

### 4.2 Views

| Feature | Approach | Phase |
|---|---|---|
| Icon view: sizes, grid, label position, item info, icon previews, groups | NSCollectionView, custom layout | P1 |
| Icon view: manual arrangement, snap to grid, Clean Up | Free-position layout + stored positions | P2 |
| List view: columns, disclosure triangles, relative dates, groups | NSOutlineView | P1 |
| Column view, including a preview column and resizable columns | Custom (§5.5) | P1 |
| Gallery view, including metadata | QLPreviewView + thumbnail strip | P1 |
| Gallery and preview-pane Quick Actions (rotate, markup, create PDF) | | P2 |
| View Options panel (Cmd-J) | SwiftUI | P1 |
| Thumbnail icon previews | `QLThumbnailGenerator` | P1 |
| Icon view window backgrounds (color or picture) | | P3 |

### 4.3 Opening and previewing

| Feature | Approach | Phase |
|---|---|---|
| Open, Open With, Other…, Always Open With | `NSWorkspace.open(_:withApplicationAt:configuration:)`, `urlsForApplications(toOpen:)` | P1 |
| Change All… (set the default app for a type) | `NSWorkspace.setDefaultApplication(at:toOpen:)` | P2 |
| Quick Look (Space or Cmd-Y), full screen, arrow-key navigation, Markup | `QLPreviewPanel` | P1 |
| Open in new tab or window (Cmd-double-click) | | P1 |
| Mount disk images | Open them with the system default handler | P1 |

### 4.4 File operations

| Feature | Approach | Phase |
|---|---|---|
| New Folder, New Folder with Selection | | P1 |
| Inline rename; warning before changing an extension | | P1 |
| Copy, Paste, Move (Cmd-Opt-V), Cut (I1) | §5.7 | P1 |
| Drag and drop with Finder's modifier keys (Option = copy, Command = move, Option-Command = alias), including to and from other apps | NSDraggingSource / Destination | P1 |
| File promises (dragging in from Mail, Photos or Safari) | `NSFilePromiseReceiver` | P2 |
| Duplicate | | P1 |
| Move to Trash, Delete Immediately, Empty Trash | | P1 |
| Put Back | Journal + Finder's records (§5.7) | P2 |
| Make Alias, Show Original, Fix Alias | Bookmark APIs | P2 ✅ |
| Batch rename (Finder's Replace / Add / Format, plus I9) | | P2 |
| Compress and expand | `ditto` for zip (same output as Finder); Archive Utility or libarchive for other formats | P2 ✅ (zip; other formats open in Archive Utility) |
| Undo and redo for file operations | §5.7 | P1 |
| Progress, pause, cancel | §5.7 | P1 |
| Operations that need admin authentication | Privileged helper (§5.11) | P3 |

### 4.5 Information and metadata

| Feature | Approach | Phase |
|---|---|---|
| Get Info window: General, More Info, Name & Extension, Comments, Open With, Preview, Sharing & Permissions | SwiftUI | P1 read-only · P2 editable |
| Inspector (Cmd-Opt-I): follows the selection and summarizes multiple items | | P2 |
| Tags: assign, remove, colors, sidebar tags, tag catalog, filter and search by tag | §5.8 | P1 |
| Comments | §5.8 | P2 |
| Locked, Stationery Pad, Hide Extension, custom icons (paste or remove) | | P2 |
| Permissions and ACL editing for items the user owns | | P2 |
| Permissions for items owned by other users | Helper | P3 |
| Calculate folder sizes | `SizeService` (§5.8) | P2 |

### 4.6 Search

| Feature | Approach | Phase |
|---|---|---|
| Scoped search with kinds and tokens | §3.1, §3.2, §5.6 | P1 |
| Recents | Spotlight query on `kMDItemLastUsedDate` (live; dates read from the `com.apple.lastuseddate#PS` xattr, Spotlight as fallback) | P1 ✅ |
| Criteria editor | | P2 |
| Smart folders: open Finder `.savedSearch` files; create and save new ones | | P2 |

### 4.7 Devices, network and cloud

| Feature | Approach | Phase |
|---|---|---|
| Volumes in the sidebar and in Computer; eject with "in use by" details; Eject All | DiskArbitration | P1 |
| Connect to Server (Cmd-K), with favorite and recent servers | NetFS `NetFSMountURLAsync` | P2 |
| Network browsing | `NWBrowser` (Bonjour `_smb._tcp`) | P2 |
| iCloud Drive: status badges, Download Now, Remove Download | Ubiquitous-item resource keys | P2 |
| File Provider locations (Dropbox, Google Drive, OneDrive, Box): sidebar entries, status, download and remove download | `~/Library/CloudStorage` + the same APIs | P2 |
| Send selection via AirDrop | `NSSharingService(named: .sendViaAirDrop)` | P2 ✅ (in Share…) |
| iCloud sharing and collaboration | `NSSharingService` | P3 |
| AirDrop window for discovering nearby devices | ✗ No public API | |
| Badges and menus from third-party Finder Sync extensions | ✗ Delivered only to Finder | |
| CD/DVD burning | ✗ Removed from macOS | |
| Time Machine "Browse backups" | ✗ v1: open Time Machine instead | |

### 4.8 System integration

| Feature | Approach | Phase |
|---|---|---|
| Services and Quick Actions in the menu bar and context menus | `NSServicesMenuRequestor` | P2 |
| Share menu | `NSSharingServicePicker` | P2 ✅ |
| Default file viewer ("Show in Finder" in other apps opens RealFinder) | §5.12 | P2 |
| Dock menu with windows and recent folders | | P2 |
| `realfinder://` URL scheme | | P2 |
| AppleScript dictionary, Shortcuts actions (App Intents), `rf` command-line tool | | P3 |
| Desktop icons and Stacks | ✗ Finder keeps the desktop (Q3) | |

---

## 5. Architecture

### 5.1 Platform decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language | Swift 6.4 with strict concurrency | Compile-time data-race checking matters with this much background I/O |
| Main UI | AppKit | NSOutlineView and NSCollectionView reuse cells, so they handle 100k+ rows. AppKit also has mature drag and drop (spring loading, modifier keys, file promises), inline editing, type-select, rubber-band selection and menu validation through the responder chain. SwiftUI's List, Table and LazyVGrid still fall short here at this scale. |
| Secondary UI | SwiftUI hosted in AppKit (`NSHostingView`) | Settings, Get Info, Inspector, View Options and onboarding are form-like UIs that are faster to build in SwiftUI |
| Deployment target | macOS 26 | Matches the development machine and the current system look (Liquid Glass), with no backward-compatibility code paths (Q1) |
| Persistence | SQLite via GRDB (SwiftPM) | Predictable performance, explicit migrations and queryable caches. SwiftData and Core Data add little for these simple tables. |
| Distribution | Signed with Developer ID, notarized, hardened runtime, not sandboxed | A general file manager can't work inside the App Sandbox. Updates via Sparkle (Q2). |
| Tests | Swift Testing for unit and integration tests; XCTest for performance (`measure`) and UI tests | |

### 5.2 Module layout

```
RealFinder/
├─ RealFinder.xcodeproj
├─ App/                 AppKit shell: AppDelegate, menus, window/tab controllers, toolbar, onboarding
├─ Packages/
│  ├─ RFModel/          Pure Swift, no AppKit, no I/O: FileItem, Location, Arrangement, Presentation,
│  │                    KindCategory, SearchQuery + parser, sort/group/filter engine
│  ├─ RFFileSystem/     Enumeration, FSEvents watcher, volume monitor, metadata read/write
│  │                    (tags, flags, comments, aliases), icon & thumbnail services, folder sizes
│  ├─ RFOperations/     File-operation engine: planning, conflicts, execution, journal, undo
│  ├─ RFSearch/         Planner, Spotlight + Crawl backends, result merging
│  ├─ RFStore/          SQLite: view settings, sidebar, journals, caches, saved searches
│  └─ RFUI/             Icon/list/column/gallery views, sidebar, path & status bars, preview pane,
│                       Get Info, inspector
├─ Helper/              (P3) privileged launchd daemon + XPC protocol
└─ Tests/               Fixtures, generated trees, disk-image filesystem matrix, perf suites
```

**As built (M1):**
- The project is a single Swift package rather than an Xcode project.
- The targets are `CFastFS` (the C helper for `getattrlistbulk`), `RFModel`, `RFFileSystem`, `RFUI` and the `RealFinder` executable.
- `scripts/bundle.sh` wraps the executable in an ad-hoc-signed `.app`.
- Xcode opens `Package.swift` directly. An `.xcodeproj` can be added when signing and distribution need one.
- `RFStore` isn't a separate target yet. A small JSON store in RFFileSystem (`AppSupportStore`) holds view settings and the session until the SQLite store lands.

**Dependency rules:**

- RFModel depends on nothing.
- RFUI never touches the filesystem directly; it calls services.
- Only RFFileSystem and RFOperations make syscalls on user files.

This keeps G3 enforceable in code review: no `FileManager` calls in RFUI.

### 5.3 Core data model

```swift
/// Stable identity of a filesystem object while its volume is mounted.
/// Persisted form uses the volume UUID instead of dev_t.
struct FileID: Hashable, Sendable {
    let device: dev_t
    let inode: UInt64
}

/// Immutable value snapshot of one item. Built off-main; cheap to copy.
struct FileItem: Identifiable, Hashable, Sendable {
    let id: FileID
    let url: URL
    let name: String            // on-disk name
    let displayName: String     // localized; extension hidden if applicable
    let contentType: UTType
    let flags: ItemFlags        // directory, package, symlink, alias, hidden, locked, executable,
                                // extensionHidden, hasCustomIcon, mountPoint
    let size: Int64?            // logical bytes; nil for folders
    let allocatedSize: Int64?
    let created, modified, added: Date?
    let tags: [Tag]
    let cloud: CloudStatus?     // .current, .notDownloaded, .downloading(p), .uploading(p), .error
}
```

- Expensive attributes are stored in side tables keyed by `FileID`: last-opened date, computed folder size, version and comments. This keeps `FileItem` immutable and enumeration fast. The arrangement engine reads these tables only when the active sort or visible columns need them.
- Kind strings come from a cache keyed by UTType and are not stored per item.

```swift
enum Location: Hashable, Codable, Sendable {
    case folder(URL)
    case search(SearchQuery)
    case smartFolder(URL)               // .savedSearch file
    case recents, trash, computer, network, iCloudDrive
    case tag(String)
}

@MainActor @Observable
final class BrowserState {              // one per tab
    private(set) var location: Location
    private(set) var history: NavigationHistory
    var arrangement: Arrangement        // resolved via §3.3
    var presentation: Presentation
    private(set) var snapshot: ItemSnapshot
    var selection: Set<FileID>
    var focusAnchor: FileID?
    private(set) var loadState: LoadState   // .loading .partial(n) .complete .unreachable(Error)
}
```

**Data flow**

```
 Directory loader / search backends ──(batches of FileItem)──▶ ItemStore (actor, per location)
                                                                │  raw items keyed by FileID
 FSEvents watcher ──(changed paths/inodes)──▶ re-stat ──────────┘
                                                                ▼
                                   ArrangementEngine (off-main): filter → sort → group
                                                                │  ItemSnapshot (generation N)
                                                                ▼
                                   BrowserState (MainActor), drops stale generations
                                                                │
                       ┌──────────────┬──────────────┬──────────┴───┐
                     Icon           List         Column        Gallery    ← same snapshot, same selection
```

An `ItemSnapshot` contains three things:

- An ordered `[FileItem]`.
- Group ranges.
- A map from `FileID` to index.

Views diff consecutive snapshots by `FileID`, so live changes animate in place without a reload.

### 5.4 Directory loading and change monitoring

- **Enumeration: `getattrlistbulk(2)`** (decided in M0, S1). It lists 100k entries with types in about 270 ms. `FileManager` takes 1.3 s with minimal keys and 18 s with the keys a `FileItem` needs.
  - A small C helper does the attribute parsing.
  - `contentType` comes from the extension through a memoized `UTType(filenameExtension:)`, with no LaunchServices call per item.
  - Packages are directories whose type conforms to `com.apple.package`, plus the FinderInfo bundle bit. Hidden items have the `UF_HIDDEN` flag or a leading dot.
  - `FileManager` remains the fallback for filesystems that don't support bulk attributes.
- **Streaming.** The first batch of about 200 items is published immediately, followed by batches about every 50 ms. Large folders appear instantly and fill in.
- **Lazy attributes.** Some data is fetched only when a visible column, the active sort or a visible cell needs it:
  - Tags. Reading them costs about 17 µs per file, or 1.75 s per 100k files (S1d). They load in the background after first paint, visible rows first. A full pass runs only when tags are sorted on, grouped on or filtered on. In indexed locations, a Spotlight `kMDItemUserTags` query scoped to the folder can return just the tagged items.
  - Spotlight-only attributes (Date Last Opened, Version)
  - Folder sizes
  - Thumbnails
- **Change monitoring: one FSEvents stream per watched directory**, shared by every subscriber to that directory (decided in M1). The directories watched are those currently on screen: all tabs, expanded list rows and column-view columns.
  - An earlier single shared stream had to restart whenever that set changed. A restart either loses events or replays history, and the replay caused spurious reloads of other folders, which a regression test now covers.
  - Each stream is running before `subscribe` returns, so a folder listed afterwards can't miss a change.
  - The streams use directory-level events. In M1 an event re-lists the folder (100k entries take ~270 ms). Re-statting only the affected entries comes later.
  - If events were dropped, or a subdirectory must be rescanned (`MustScanSubDirs`), that directory is fully rescanned.
  - **Latency:** fseventsd delivers events 0.2–0.8 s after a change, even with the stream latency set to 0.1 s (measured in M1). RealFinder's own file operations (M2) update the view directly instead of waiting for FSEvents. A `kqueue`/`DispatchSource` watch on each visible directory could make adds, removes and renames from other apps instant (follow-up).
- **Network volumes.** FSEvents doesn't report changes that other clients make on SMB or NFS volumes. Visible network folders are listed again when the window becomes active and polled every 5 s by default while visible. The diff is cheap.
- **Per-volume isolation.** Each volume gets its own listing queue (up to 4 listings at once) and its own serial queue for metadata lookups. A hung SMB mount stalls only its own queues.
  - Metadata such as path chains, folder keys and free space loads in parallel with the listing, never in front of it.
  - Free space ("available for important usage") takes 17–170 ms to compute, so it's cached per volume for 30 s. Before M3 it ran ahead of every listing on a serial queue, and under load it delayed listings by seconds.
  - After 3 s with no response, the tab shows "‹Server› isn't responding" with Retry and Disconnect buttons. The rest of the app is unaffected.
  - Navigating away cancels any loads in progress (structured concurrency).

### 5.5 Views

All four views implement one protocol. A `BrowserViewController` hosts the active view and owns menu and keyboard actions, so behavior is identical in every mode.

```swift
@MainActor protocol BrowserContentView: AnyObject {
    func apply(_ snapshot: ItemSnapshot, animated: Bool)
    var selection: Set<FileID> { get set }
    func reveal(_ id: FileID)
    func beginRename(_ id: FileID)
    func frame(for id: FileID) -> NSRect?     // Quick Look zoom, drag images
}
```

- **List view: NSOutlineView.**
  - Expanding a row loads its children lazily through the same loader and arrangement.
  - Clicking a header edits `arrangement.sort`.
  - Group rows float at the top while scrolling.
  - Column set, order and widths are stored in `ListOptions`.
- **Icon view: NSCollectionView** with a custom grid layout.
  - Labels can sit below or to the right of icons, with an optional item-info line.
  - When `sort == .manual`, a free-positioning layout is used.
  - Groups get section headers.
- **Column view: custom.**
  - A horizontally scrolling row of NSTableViews, one per folder in the path, followed by a preview column.
  - NSBrowser was considered and rejected because it gives too little control over async loading, sorting, inline rename, drag and drop, and cell layout.
  - *As built (M4):* columns are laid out by hand (fixed widths, full visible height) in a flipped document view. Constraining them to the clip view made the window shrink to fit. The tab's location is the last full ("current") column; earlier columns are its ancestors back to where column browsing started. A single selected folder is shown in a "peek" column; a single selected file gets the preview column. Each column loads and watches its own folder while on screen and uses the tab's one `Arrangement`. The `QLPreviewView` gets its item only once it is in a window (it asserts otherwise).
- **Gallery view.**
  - A large preview (`QLPreviewView`) above a horizontal NSCollectionView strip of thumbnails.
  - An optional sidebar shows metadata and Quick Actions.
  - *As built (M4):* the strip is a custom horizontal view in the shared order, and the info panel shows the Get Info basics. The first item is selected on entry. Quick Actions are P2.
- **Mode switch.** The controller swaps in the new child view controller, then calls `apply(snapshot)`, sets `selection`, and calls `reveal(anchor)`. Nothing is reloaded or re-sorted.

**Icons and thumbnails**

- Generic icons are cached per UTType (`NSWorkspace.icon(for:)`).
- Per-file icons are fetched only for apps, volumes, aliases and items with custom icons.
- Thumbnails come from `QLThumbnailGenerator`, requesting `[.icon, .thumbnail]` (apps fail with `.thumbnail` alone; S7):
  - Requested only for visible cells and cancelled when a cell scrolls away.
  - Duplicate requests are coalesced.
  - Held in a memory-bounded `NSCache`.
- Thumbnails don't download dataless cloud files (verified for iCloud Drive in M0, S7), but they can take ~2 s. Cells show the type icon until the thumbnail arrives.

**Quick Look.** The `QLPreviewPanel` data source is the current selection in snapshot order. Using the arrow keys in the panel moves the selection.

### 5.6 Search engine

Two backends share one interface. (A third, Catalog via `searchfs(2)`, was dropped in M0: it works on APFS but took 65 s to scan the Data volume; S2.)

```swift
protocol SearchBackend: Sendable {
    func capability(for q: SearchQuery, on volume: VolumeInfo) -> Capability    // .full .partial .none
    func results(for q: SearchQuery) -> AsyncThrowingStream<[SearchHit], Error> // batches; live
}
```

| Backend | Coverage | Strengths | Limits |
|---|---|---|---|
| **Spotlight** (MDQuery / NSMetadataQuery) | Indexed volumes | Fast; searches contents; rich metadata; live updates | Skips hidden files and system or excluded paths. Most network shares and many external drives aren't indexed, and the index can lag behind the disk. |
| **Crawl** (parallel `getattrlistbulk` walk) | Any mounted filesystem | Complete and exact; finds hidden files; works on SMB and exFAT | Cost grows with tree size; names and attributes only |

**Planner**

| Query | Backends used |
|---|---|
| Folder scope, Names | Spotlight and Crawl, always in parallel. Spotlight fills the list right away, and Crawl adds what Spotlight missed. Crawl is authoritative. |
| Folder scope, Names & Contents | Spotlight. If indexing is off for the volume (volume-level check), a banner says "‹Volume› isn't indexed; searching names only", and Crawl runs instead. |
| This Mac, Names | Spotlight. With "Include system & hidden files" turned on, a low-priority exhaustive Crawl also runs, with visible progress. |
| This Mac, Names & Contents | Spotlight |
| Item-set scope (Recents, tag, smart folder, Trash) | The set is filtered in memory |

**Merging.** Hits are de-duplicated by `FileID`, with the path as a fallback. We re-stat every hit before showing it. That keeps attributes consistent no matter which backend found the item, and it drops stale Spotlight hits for files that have since been deleted.

**Crawl details**

- Breadth-first walk with bounded parallelism: 16 directories in flight on SSDs, and about 2 on spinning disks or network volumes, based on volume properties.
  - Measured in M3 on an M5 SSD, over a home folder of 194k folders, skipping hidden ones: 16 parallel folders took 19 s, 8 took 26 s, and `find(1)` took 63 s.
  - The time goes to directory reads in the kernel, so large folder searches show Spotlight's results first while the crawl streams in.
- A crawl-only query (names, sizes and dates, with no contents and no last-opened dates) counts as finished as soon as the crawl finishes. The search doesn't wait for Spotlight to finish gathering, which took ~3 s even for small folders.
- Runs at utility QoS and delivers results in batches every 50 ms.
- Doesn't descend into packages (unless `includePackageContents` is set), other volumes or symlinks.
- Supports an optional user exclusion list, such as `.git` or `node_modules`.
- Uses fd-relative `*at()` syscalls, so very deep paths work.
- Results stay live through a recursive FSEvents stream on the scope root.

**As built (M3):**
- **Module:** search lives in a new `RFSearch` target (planner, Spotlight translation, `NSMetadataQuery` runner). The crawl is `TreeWalker` in RFFileSystem, a parallel `getattrlistbulk` walk that filters raw names before building items.
- **Path spelling:** Spotlight hits come back with canonical paths (`/private/var/…`). They are respelled to match the scope the user chose, so they merge with crawl results and show sensible "Where" paths.
- **Live updates:** after the initial gathering, Spotlight results update live. Crawl results don't yet; that's a follow-up, using recursive FSEvents on the scope root.
- **No Spotlight:** queries Spotlight can't express (regexes) crawl the scope instead. For This Mac, that means crawling `/`.

**No per-folder index detection.** M0 (S3) showed that Spotlight's coverage can't be predicted reliably per folder. Probes contradicted each other, Spotlight answered queries even on an unindexed disk image, and new files took 0.2–2.6 s to be indexed. So the planner treats Spotlight as fast but possibly incomplete or stale, and treats Crawl plus FSEvents as authoritative. Only volume-level indexing status (as reported by `mdutil -s`) is used, and only for the contents-search banner.

### 5.7 File operations engine

**As built (M2).** The engine is the `RFOperations` module: `OperationRequest`, an `Execution` per job on its own I/O queue, `OperationCenter`, and `OperationJournal`.
- **Replace** moves the existing item to the Trash rather than deleting it, so Replace can be undone. Finder deletes the existing item.
- **Same-volume copies** clone the whole tree with one `clonefile`.
- **Undo** replays each job's ordered step log in reverse. Redo replays the log of what the undo itself did.
- **Free space.** The pre-flight check uses the larger of the "available for important usage" figure and `statfs`. The former reports 0 on disk images and external disks, which blocked every copy to them; the filesystem matrix found this.
- **`RENAME_EXCL` fallback.** `renamex_np(RENAME_EXCL)` isn't supported on exFAT (and some network filesystems). There, the engine checks that the destination doesn't exist and then does a plain rename.
- **Verified by:**
  - a fuzz test: random operations, then undo all and redo all, with exact tree comparison. 150 seeds, 3,750 operations.
  - a filesystem matrix on APFS, case-sensitive APFS, HFS+, exFAT and FAT32 disk images: copy, cross-volume move, undo, case-only rename, and a short fuzz run on each.
  - a `kill -9` mid-copy test, using a probe process: no partial file appears under the real name, the source is intact, and the journal recovers the leftover.

**Job lifecycle:** `Request → Plan → Execute → Finish`

1. **Plan** (pre-flight, in the background):
   - Expand the sources into a tree of items and total the bytes.
   - Detect conflicts.
   - Check free space and write permission.

   Cheap operations, such as a rename or a move on the same volume, skip straight to Execute.
2. **Execute** item by item. Each step is recorded in the journal (SQLite).
3. **Finish:**
   - Show a summary.
   - List any failed items with Retry, Skip and Show buttons.
   - Register the undo action.

**Primitives**

| Operation | Implementation |
|---|---|
| Rename; move within a volume | `renamex_np(…, RENAME_EXCL)` so nothing is silently overwritten; case-only renames are handled explicitly |
| Copy within an APFS volume | `copyfile(…, COPYFILE_ALL \| COPYFILE_CLONE)`: an instant clone |
| Copy across volumes | Our own tree walk, calling `copyfile(COPYFILE_ALL)` per file with a status callback for byte-level progress. Directories are created first, and their metadata and dates are applied after their contents are copied. |
| Move across volumes | Copy the item, verify it, then remove the source item, and only after that item fully succeeded |
| Trash | `FileManager.trashItem` + a put-back journal entry |
| Delete Immediately, Empty Trash | `removefile(3)` in the background, with progress |
| Alias | `URL.bookmarkData(options: .suitableForBookmarkFile)` + `URL.writeBookmarkData` |

**Safety**

- **Partial copies are never visible.** Each file is copied to a hidden temporary name in the destination (`.‹name›.rfpartial`) and renamed into place when it's complete. After a cancel or crash, the journal identifies leftover files, which are cleaned up at the next launch.
- **Conflicts.** The options are Ask (default), Replace, Skip, Keep Both ("name 2"), Replace if Newer, and Merge (folders only), with an "Apply to all" checkbox. A folder is never replaced by a file, or a file by a folder, without explicit confirmation.
- **Errors are handled per item, and the job keeps going.** Error messages are written in plain language, with the underlying code available. For example: "Couldn't read 'x.mov': the disk reported an I/O error (EIO)." Finder would show "error -36".
- **Cloud items are coordinated.** Items in iCloud Drive and File Provider domains are accessed through `NSFileCoordinator`.

**Scheduling**

- A single `OperationCenter` actor schedules all jobs.
- Jobs that touch the same physical device run one at a time by default, which suits spinning disks. Jobs on different devices run in parallel.
- A toolbar progress button lists the jobs with pause, resume and cancel controls, similar to Safari's downloads list.
- Progress is also published through `Progress.publish()` with file URLs, so other apps, including Finder, can show it.

**Undo.** There is one app-wide undo stack for file operations, as in Finder. Each successful job registers its inverse:

| Operation | Undo |
|---|---|
| Move | Move back |
| Copy | Move the copies to the Trash |
| Rename | Rename back |
| Move to Trash | Put back |
| New folder | Move it to the Trash |
| Tag change | Restore the previous tags |

- Before undoing, the engine checks that the items are still where it left them, matching by `FileID`. If they aren't, the undo fails with a clear message.
- Delete Immediately and Empty Trash can't be undone, and both ask for confirmation.

**Put Back**

- For everything RealFinder moves to the Trash, the journal records the `FileID`, original path, trashed URL and date.
- `FileManager.trashItem` writes the same `ptbL` (put-back location) record to the Trash's `.DS_Store` that Finder writes (verified in M0, S4). So Finder can Put Back items RealFinder trashed.
- For items Finder trashed, RealFinder reads the `ptbL`/`ptbN` records from `.DS_Store`. This is read-only parsing of a private format, isolated behind an adapter (S10).
- Reading `~/.Trash` requires Full Disk Access. Without it, the Trash location shows the Full Disk Access explanation, but Move to Trash still works.
- If there's no record, Put Back asks for a destination.
- *As built (M5):* `trashItem` writes its `.DS_Store` record asynchronously, and items trashed in quick succession lose theirs (three trashed back to back kept one record). So RealFinder's journal (`putback.json`: path in the Trash → original path, plus the item's device and inode so a different item at that path isn't mistaken for it) is the primary source, and the `.DS_Store` reader (`DSStore`, read-only, bounds-checked) covers items Finder trashed. The Trash location (`Location.trash`) merges the home Trash and every volume's `.Trashes/<uid>`; if the home Trash can't be read, it shows the Full Disk Access explanation. Empty Trash (⇧⌘⌫, ⌥ skips the question) deletes the contents of every Trash as one job, and reports a Trash it can't read instead of skipping it.

**Cut (I1)**

- Cmd-X writes the file URLs to the pasteboard along with a private "cut" marker and dims the items.
- Cmd-V in RealFinder then moves them.
- If anything else changes the pasteboard, the cut is cancelled.
- Pasting into Finder copies the items instead, because Finder ignores our marker. This is acceptable and will be documented.

### 5.8 Metadata

- **Tags.**
  - *As built (M4):* tags load off the main thread for visible items and are cached by `FileID` until the item's status-change time (`ATTR_CMN_CHGTIME`) moves, which tag edits do. List and icon cells show up to three dots. Assigning goes through the operations engine (`.changeTags`, `.setTags`), so it shows progress and can be undone. The sidebar's Tags section comes from Finder's `FavoriteTagNames`; each entry is a This Mac search for `tag:"Name"`.
  - Read through `tagNamesKey`. Colors come from the `com.apple.metadata:_kMDItemUserTags` xattr, whose entries look like `Name\n<colorIndex>`.
  - Write **only** through `NSURL.setResourceValue(_:forKey: .tagNamesKey)`. The API also updates the FinderInfo label color. Writing the raw xattr leaves that label stale (S5).
  - Finder's sidebar tag list is `FavoriteTagNames` in the `com.apple.finder` preferences, which RealFinder can read. The full catalog syncs through iCloud and isn't readable. RealFinder builds its tag list from those favorites plus tags discovered on files (through Spotlight and xattrs), and never writes Finder's catalog.
- **Comments** (P2; decided in M0, S6).
  - Read from the `kMDItemFinderComment` xattr. Finder updates that xattr whenever it sets a comment.
  - Finder ignores a comment written only as the xattr. So writes go through Apple Events to Finder (`set comment`), which needs the Automation permission, and RealFinder also writes the xattr.
  - If the user declines Automation, write the xattr only. Spotlight then sees the comment, and the UI says Finder won't show it.
- **More Info.** `MDItem` attributes such as dimensions, duration, codecs and Where From.
- **Flags.**
  - Locked (`uchg`, `isUserImmutableKey`)
  - Hidden extension
  - Stationery Pad
  - Custom icon (`NSWorkspace.setIcon`)
- **Permissions.**
  - POSIX permissions plus ACLs (`acl(3)`).
  - Editing is P2 for items the user owns. Items owned by other users go through the helper in P3.
  - "Apply to enclosed items" runs as a file operation job.
- **Folder sizes.**
  - A `SizeService` adds up allocated and logical sizes using the crawl walker.
  - Results are cached in SQLite by `FileID` and invalidated by FSEvents.
  - The last FSEvents event ID is stored per volume. At launch, events since that ID are replayed to invalidate stale cache entries instead of recomputing everything.

### 5.9 Volumes, network and cloud

- **Volume monitor.**
  - Listens for `NSWorkspace` mount, unmount and rename notifications and lists volumes with `FileManager.mountedVolumeURLs`.
  - Tracks whether each volume is local or network, removable or ejectable, and internal.
  - Reports available capacity using `volumeAvailableCapacityForImportantUsageKey`. This matches Finder's "available" figure, which includes purgeable space.
- **The startup disk** appears as "Macintosh HD" rooted at `/`. Like Finder, RealFinder hides the split between the system and Data volumes, which are joined by firmlinks.
- **Eject.**
  - Uses DiskArbitration to unmount and eject.
  - If something blocks the eject, RealFinder shows the reason. It also tries to name the blocking process by running `lsof` on the mount point in the background.
  - Force Eject is offered.
  - *As built (M4):* `diskutil eject` / `unmountDisk force` on the whole device (from `statfs`), run off the main thread. `diskutil` already handles APFS containers and disk images and names the dissenting process; `lsof +f` adds every process of ours with files open. Network mounts use `diskutil unmount`. Ejecting a disk ejects all of its volumes (Finder asks first; we don't yet). Tabs on a volume that unmounts go to Computer. Eject All is still to do.
- **Connect to Server.**
  - Uses `NetFSMountURLAsync`.
  - The system's own authentication dialog handles credentials and the Keychain, so RealFinder never sees or stores passwords.
  - Favorite and recent server URLs are saved.
- **Network browsing.** `NWBrowser` discovers `_smb._tcp` services. Other protocols (NFS, WebDAV) can be reached by typing a URL in Connect to Server.
- **iCloud Drive and File Provider locations** (Dropbox, Google Drive, OneDrive and Box live under `~/Library/CloudStorage`):
  - Each gets a sidebar entry.
  - Status comes from the `ubiquitousItem*` resource keys.
  - Download Now calls `startDownloadingUbiquitousItem`, and Remove Download calls `evictUbiquitousItem`.
  - RealFinder never reads file contents on its own initiative, so browsing never triggers downloads.

### 5.10 Persistence

- **UserDefaults** hold app preferences.
- **SQLite** (RFStore, GRDB) holds everything else:

| Table | Contents |
|---|---|
| `view_settings` | Scope (a location class, or a folder as volume UUID + file ID + last known path), arrangement JSON, presentation JSON |
| `icon_positions` | Folder, item `FileID`, x, y (manual arrangement) |
| `sidebar_items` | Section, order, bookmark data, display name |
| `op_journal` | Jobs and their per-item steps and states, for crash recovery |
| `putback` | `FileID`, original path, trashed URL, date |
| `size_cache` | Folder `FileID`, sizes, FSEvents ID at computation time |
| `saved_searches` | Query JSON (also exportable as a Finder-compatible `.savedSearch`) |
| `servers` | Favorite and recent server URLs (never credentials) |
| `fsevents_cursor` | Volume UUID → last seen event ID |

- Sidebar items are stored as bookmarks, so they survive moves and renames.
- **First-run import** (P2, best effort): Finder's sidebar favorites, its tag list, and its "Show all filename extensions" preference. RealFinder only ever reads Finder's private formats; it never writes them.

### 5.11 Permissions, privacy (TCC) and privileges

- **Packaging.** Not sandboxed; hardened runtime; Developer ID.
- **Privacy permissions (TCC).** macOS asks for permission the first time an app opens Desktop, Documents, Downloads, removable volumes or network volumes. Other areas require Full Disk Access, including Mail, Messages, Safari data and other users' Library folders.
  - First-run onboarding explains this and links directly to System Settings › Privacy & Security › Full Disk Access.
  - RealFinder detects Full Disk Access by probing a protected path.
  - *As built (M4):* the probe lists `~/Library/Safari`, `~/.Trash` or `~/Library/Mail`. Onboarding is a single alert on first launch, skipped when Full Disk Access is already granted. Settings › Privacy shows the state and opens the right System Settings page, and a folder that fails with a permission error says Full Disk Access may help.
  - Without it the app still works. Protected folders show an explanation instead of an error or an empty list.
- **Admin operations (P3).** A launchd daemon is registered through `SMAppService.daemon` and talks to the app over XPC.
  - The helper verifies the caller's code signature using its audit token.
  - It exposes a narrow API: copy, move, delete, chmod, chown and ACL changes on explicit paths. It never runs shell commands.
  - Each operation requires an Authorization Services right, so the user sees an admin prompt, as they would in Finder.
- **Apple Events to Finder.** Avoided unless M0 shows it's the only way to make comments or the tag catalog work with Finder. Using it requires the Automation permission.

### 5.12 System integration

- **Default file viewer** (P2, opt-in in Settings).
  - The toggle sets the global `NSFileViewer` default to RealFinder's bundle ID. `NSWorkspace.activateFileViewerSelecting(_:)` honors this setting, and most apps use that call for "Show in Finder".
  - The toggle can optionally make RealFinder the default handler for `public.folder` as well.
  - Turning the toggle off fully restores the previous setup.
  - Caveats: this is an undocumented convention (Path Finder and ForkLift rely on it), and apps that script Finder directly will still open Finder (S8).
- **Services and Quick Actions.** The browser views implement `validRequestor(forSendType:returnType:)` and `writeSelection(to:types:)`. AppKit then adds Services and Quick Actions to the app menu and to context menus.
- **Share.** `NSSharingServicePicker` (AirDrop, Mail, Messages and others).
- **Entry points:**
  - `open -a RealFinder <path>`
  - `realfinder://open?path=…` (P2)
  - An `rf` command-line tool (P3)
  - App Intents for Shortcuts (P3)
  - An AppleScript dictionary (P3)

### 5.13 Concurrency and performance

**Rules**

1. The main actor does UI work only. RFUI makes no filesystem calls (enforced by lint and code review).
2. All I/O runs on per-volume executors. All models are `Sendable` value snapshots.
3. Every load and search can be cancelled, and navigating away cancels the previous one.
4. Arrangement runs off the main thread and tags each result with a generation number. Stale results are dropped.

**Budgets** (Apple-silicon Mac with an internal SSD, measured by the perf suite with `os_signpost`)

| Scenario | Target |
|---|---|
| Open a folder with 1k items | Fully displayed in < 50 ms |
| Open a folder with 10k items | First items in < 100 ms; complete in < 400 ms |
| Open a folder with 100k items | First items in < 150 ms; complete in < 3 s; UI responsive throughout |
| Switch view mode (10k items) | < 50 ms, with no reload |
| Re-sort 100k items | < 300 ms, off the main thread |
| Scrolling | No dropped frames at 120 Hz with thumbnails on |
| Search, first results (Spotlight) | < 200 ms |
| Unresponsive network volume | UI never blocks; "not responding" state appears within 3 s |
| Model memory for 100k items | < 150 MB |

**Measured in M1** (optimized build, M5 MacBook Air; run with `RF_PERF=1 swift test -c release -Xswiftc -enable-testing --filter PerformanceBudgetTests`):

| Scenario | Measured | Budget |
|---|---|---|
| Open 1k items, complete | 8 ms | 50 ms |
| Open 10k items, first items / complete | 6 / 54 ms | 100 / 400 ms |
| Open 100k items, first items / complete | 6 / 874 ms | 150 ms / 3 s |
| Switch view mode, 10k / 100k items (worst, including the first switch) | 40–53 ms / 38–53 ms | 50 / 250 ms |
| Re-sort 100k items (size, kind, name, date) | 66–84 ms | 300 ms |

How these were met:
- **Sorting.** Arrangement precomputes each item's values for the active sort keys once; kind, extension and folder strings become ranks. It then sorts index arrays rather than `FileItem` structs, and compares names with one `memcmp`. Before, re-sorting took 0.65–1.8 s; sorting by kind looked up a kind string under a lock on every comparison. An equivalence test checks the new order against the original comparator.
- **View switches.** Content views are kept per mode and swapped rather than rebuilt, and a view that already shows the current snapshot isn't re-applied.
  - List rows are created on demand, not as 100k objects up front.
  - Once a folder has been quiet for 300 ms, the other view is built and laid out transparently in the background, so even the first switch is a swap.
  - List cells use manual layout.

**Name sorting** (M0, S1b/c). `localizedStandardCompare` takes 810–930 ms for 100k names, and parallelizing it doesn't help because it serializes internally.

Instead, each `FileItem` gets a precomputed natural sort key when it's enumerated:
- The name is folded for case, diacritics and width.
- ASCII punctuation gets ICU-like weights.
- Each run of digits is encoded so that byte order equals numeric order.
- Keys are compared as bytes. When two keys are equal, `localizedStandardCompare` breaks the tie.

This takes 252 ms for 100k names including building the keys, and less for a re-sort once keys exist. It matched Finder's order exactly on synthetic data and on 85,904 of 85,905 real filenames. Before M1 ships, two refinements remain:
- Non-ASCII symbols must sort with punctuation.
- Names in non-Latin scripts must fall back to `localizedStandardCompare`.

---

## 6. UI specification

### 6.1 Window layout

```
┌───────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  < >  Projects      [icon|list|col|gal] [Sort v] [Share] [Tags] [...]  [ Search ] [Jobs 2] │  toolbar
├──────────────┬── tabs: [ Projects ] [ Downloads ] [+] ───────────────────────────────────┤
│ Favorites    │ Search: [Projects v][This Mac] [x] Subfolders  Names v | All Images Docs …│  scope bar (only while searching)
│   Recents    ├─────────────────────────────────────────────────┬──────────────────────┤
│   Apps       │                                                 │                      │
│   Desktop    │              content view                       │    preview pane      │
│   Documents  │      (icon / list / column / gallery)           │    (optional)        │
│   Downloads  │                                                 │                      │
│ iCloud       │                                                 │                      │
│ Locations    │                                                 │                      │
│ Tags         │                                                 │                      │
├──────────────┴─────────────────────────────────────────────────┴──────────────────────┤
│ Macintosh HD › Users › me › Projects                          (path bar; click to edit)  │
│ 3 of 128 selected, 4.2 MB  ·  212 GB available                    [ icon size slider ]   │  status bar
└───────────────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 Menus

The menus mirror Finder's structure and item names (RealFinder, File, Edit, View, Go, Window, Help), so users find commands where they expect them. Additions go at the end of their menu.

Every command is a menu item. That means users can customize any shortcut in System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts.

### 6.2.1 Help

The system Help menu's search mixes in results unrelated to the app, so RealFinder doesn't use Apple Help.
- **RealFinder Guide** (⌘?, the Help menu, or a toolbar **?** button) opens the bundled guide (`Sources/RFUI/Guide/guide.html`) in its own window.
- The guide window has a search field that searches only the guide.
- `NSApp.helpMenu` points at a menu that's never shown, and the visible Help menu's title isn't the plain word "Help". AppKit adds its search field to whichever menu it identifies as the Help menu, so this keeps the field out of ours.

### 6.3 Keyboard

The defaults are Finder's published shortcuts, from the Finder section of Apple's "Mac keyboard shortcuts" support article. That includes drag modifiers and Finder's arrow-key behavior in list and column views. Changes and additions:

| Shortcut | Action | Compared with Finder |
|---|---|---|
| Cmd-F | Search the current folder (§3.1) | Finder searches This Mac by default |
| Cmd-X | Cut (I1) | Disabled for files in Finder |
| Cmd-Shift-G | Focus the editable path field (I2) | Same command; inline instead of a sheet |
| Cmd-Opt-C | Copy path, with a Copy As submenu (I8) | Same, plus the submenu |
| Return | Rename; a setting can change it to Open (I11) | Same by default |
| Shift-click a column header | Add a secondary sort key | New |
| (none) | New File, Open in Terminal | New; nearby Finder shortcuts are already taken, so no default is assigned |

---

## 7. Edge-case checklist

**Names and text**

- Case-insensitive vs case-sensitive volumes, including case-only renames (`readme` → `README`).
- Unicode normalization: HFS+ stores NFD and APFS is normalization-insensitive. Compare and search on normalized forms, but display names as stored.
- A `/` in a display name is stored as `:` on disk, and vice versa.
- Localized folder names (`Applications`, `.localized` bundles): display the localized name, operate on the real one, and match either in search.
- Hidden items: dot-files, the `UF_HIDDEN` flag, and hidden extensions.
- Names close to the 255-byte UTF-8 limit when a " 2" or " copy" suffix is added.

**Item types**

- Packages (`.app`, `.photoslibrary`, `.bundle`) behave like files unless Show Package Contents is used.
- Symlinks, aliases and firmlinks are handled differently. Broken links and aliases get a badge and a "Fix Alias…" option.
- Hard links inside copied trees: match Finder's behavior and document it.
- Dataless cloud placeholders must never be downloaded by accident. That covers thumbnails, size calculation, search crawls and Quick Look on items that aren't downloaded.

**Filesystems and volumes**

- Volumes without xattr support (FAT32, exFAT, some SMB): copies produce AppleDouble `._` files, which `copyfile` handles.
- Files over 4 GB being copied to FAT32: fail at the pre-flight check, not halfway through.
- Folders with more than 100k entries, and paths longer than 1024 bytes (use `*at()` syscalls).
- Trash on external and network volumes (`.Trashes/<uid>`). Some network volumes have no trash, so offer "Delete immediately?" as Finder does.
- A volume disappears while it's displayed (for example, a USB drive is pulled). The tab falls back to Computer and explains why.

**Permissions**

- Folders without read or execute permission: show a lock badge and an explanation, not an empty folder.
- TCC-protected folders before consent is granted.
- Locked (`uchg`) items in move, trash or rename: prompt the user, as Finder does.

**Changes during operations**

- The source is deleted mid-copy, or the destination volume is unmounted.
- Clock skew on network volumes affects "Replace if Newer".

---

## 8. Testing strategy

| Layer | What | How |
|---|---|---|
| Unit (RFModel) | Sort comparators, grouping, kind matching, query parser, settings resolution, conflict naming ("name 2.ext") | Swift Testing, table-driven |
| Integration (RFFileSystem, RFOperations) | Every operation on every filesystem | Fixtures create disk images with `hdiutil`: APFS (case-insensitive and case-sensitive), HFS+, exFAT and FAT32. Tests assert that data, xattrs, ACLs, flags and dates are preserved. |
| Property / fuzz | Random sequences of operations, then undo, must leave the tree identical to the start | Seeded generator; runs nightly |
| Search parity | The same query through Crawl and through Spotlight returns the same set, apart from documented Spotlight exclusions | An indexed fixture volume |
| Performance | The budgets in §5.13 | XCTest `measure` plus signposts on generated trees of 1k, 10k and 100k items; CI fails on regression |
| Network | SMB behavior, hangs and disconnects | A local SMB share (macOS File Sharing) and a deliberately unreachable mount; a manual checklist where automation isn't practical |
| UI | Core flows: navigate, switch views (assert the order is unchanged), search from a folder, copy with a conflict, undo | XCUITest |
| Dogfooding | The §4 parity checklist, compared against Finder | Manual, at each milestone |

**Acceptance tests for the headline requirements**

1. Cmd-F in every view mode and type of location produces the scope given in the §3.1 table.
2. Each built-in category matches a fixture corpus with no false positives or false negatives.
3. For every sort key and every pair of view modes, switching modes preserves item order exactly.

---

## 9. Milestones

These are in order with exit criteria; there are no dates.

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0 Spikes** | Questions in §10 that could change the design | Each spike's answer recorded in this document |
| **M1 Browsing core** ✅ | App shell, windows and tabs, sidebar (with editable favorites), list view with inline folder expansion, icon view, `Arrangement` model (§3.3), navigation, path and status bars, Quick Look, FSEvents updates, state restoration, in-app user guide | Done: usable as a read-only daily browser; open, mode-switch and re-sort budgets met (§5.13); sort-preservation tests pass |
| **M2 File operations** ✅ | Engine; copy, move, rename, trash, new folder and duplicate; drag and drop; clipboard and cut; conflicts; progress; undo; journal | Done: fuzz suite passes on every filesystem image; no data loss on `kill -9` mid-copy |
| **M3 Search** ✅ (Recents added in M5) | Scope bar, query parser, kinds, Spotlight and Crawl backends, results view, Recents | Acceptance tests for headline requirements 1 and 2 pass |
| **M4 P1 complete** (built) | Column and gallery views, tags, read-only Get Info, View Options, Open With, eject, preferences, onboarding and TCC | The developer uses RealFinder instead of Finder for a full week. *Built:* everything in scope. Settings (⌘,): new-window folder, tabs or windows, Return renames or opens, search scope and match defaults, per-folder or same-everywhere views, Full Disk Access. Open With has Other… and ⌥ Always Open With (sets the LaunchServices default for the type). Get Info shows comments and permissions read-only. Not yet: Eject All, a confirmation before ejecting a multi-volume disk. Waiting on the week of daily use |
| **M5 Parity (P2)** | All remaining P2 rows in §4 | Parity checklist complete, except ✗ and P3 items |
| **M6 Advanced (P3)** | Privileged helper, scripting, Shortcuts and CLI, dual-pane mode, extras | — |

---

## 10. Risks and spikes

| # | Risk or unknown | Impact | Spike or mitigation |
|---|---|---|---|
| S1 | Enumeration speed of `FileManager` with prefetch vs `getattrlistbulk` on 100k-entry folders, local and SMB | Performance budgets | **Done (local):** `getattrlistbulk` chosen. Still to do: SMB measurement in M1 |
| S2 | Whether `searchfs` is supported on APFS, how fast it is, and how it interacts with firmlinks | The Catalog backend may be dropped | **Done:** works and handles firmlinks, but too slow (65 s per volume). Backend dropped |
| S3 | Reliably detecting whether a volume or folder is Spotlight-indexed | Search planner correctness | **Done:** not reliable per folder. The planner no longer depends on it |
| S4 | Whether `trashItem` records put-back information on macOS 26 and 27, and where Finder keeps its records | Put Back for items Finder trashed | **Done (macOS 26):** `trashItem` writes Finder's `ptbL` record to the Trash `.DS_Store`. Recheck on macOS 27 |
| S5 | Reading and writing Finder's tag list and colors so both apps agree | Consistent tags | **Done:** write tags only through the API; read the catalog but never write it (§5.8) |
| S6 | Making comments visible in Finder without `.DS_Store` | Comments interop | **Done:** xattr-only writes are invisible to Finder. Write through Apple Events plus the xattr (§5.8) |
| S7 | Whether thumbnails or previews of dataless cloud files trigger downloads | Unwanted downloads and bandwidth use | **Done for thumbnails** (iCloud: no download). Quick Look previews and third-party File Provider domains (Dropbox and others) are still to check in M1, alongside Quick Look |
| S8 | How `NSFileViewer` behaves on current macOS | Default-file-viewer feature | Test "Show in Finder" in common apps |
| S9 | Native window tabs with many tabs (state restoration, memory use) | Tab UX | Prototype in M1; fall back to a custom tab bar |
| S10 | Undocumented private formats (Finder favorites `.sfl*`, put-back records, tag catalog) change between macOS releases | Import and interop break | Treat as best effort, isolate behind adapters, never write private formats |
| S11 | How faithfully the copy engine preserves metadata (creation dates, ACLs, xattrs, resource forks, sparse files, hard links) compared with Finder | Data fidelity | Filesystem-matrix integration tests; compare against Finder copies |
| S12 | Network volumes that hang inside syscalls that can't be cancelled | Thread exhaustion | Per-volume executors, bounded thread counts, and abandoning the call while marking the volume unresponsive |

---

## 11. Open questions

| # | Question | Recommendation |
|---|---|---|
| Q1 | What is the minimum macOS version? | macOS 26, your current OS. Supporting older versions costs UI branching. |
| Q2 | Is this a personal tool or for public distribution? This affects Developer ID signing, notarization, Sparkle and helper signing. | Build as if it's public; it costs little up front |
| Q3 | Should RealFinder leave the desktop to Finder, or replace it (draw desktop icons itself)? | Leave it to Finder in v1 |
| Q4 | Which view-settings model should be the default: "same everywhere, with opt-in per-folder pins" or "remember per folder"? | Same everywhere; pins are opt-in |
| Q5 | Should search match Names or Names & Contents by default? | Names |
| Q6 | Should Return rename (Finder) or open? | Rename by default, with a setting |
| Q7 | Which §3.4 improvements should stay? Is dual-pane mode wanted before P3? | Keep I1–I11; dual-pane in P3 |
| Q8 | Should the default-file-viewer toggle be offered at all? | Yes, opt-in |
| Q9 | Keep the name "RealFinder"? "Finder" is an Apple trademark, so a publicly distributed app should avoid it in its name. | Decide before any public release |
