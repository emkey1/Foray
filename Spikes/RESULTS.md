# M0 spike results

Machine: MacBook Air (Mac17,4), Apple M5, 10 cores, 24 GB, internal SSD · macOS 26.6.2 · Xcode 27.0 / Swift 6.4.
Raw output for each spike is in `results/`. Rebuild and rerun with `swift run -c release <spike> …`.

| Spike | Question | Answer | Design change |
|---|---|---|---|
| S1 | How fast is `FileManager` vs `getattrlistbulk`? | `getattrlistbulk` is 7× faster than FileManager with minimal keys and **~65× faster** than FileManager with the keys a `FileItem` needs | Use `getattrlistbulk` (§5.4) |
| S1b | Can we sort 100k names in under 300 ms in Finder order? | Not with `localizedStandardCompare` (810–930 ms). Parallelizing it doesn't help. Precomputed natural keys take **252 ms** and match Finder's order exactly on synthetic data | Precomputed sort keys (§5.13) |
| S1c | Do those keys match Finder on real filenames? | 1 disagreement in 85,905 names, caused by a non-ASCII symbol (`•`) | Classify non-ASCII scalars (§5.13) |
| S1d | What do tags cost? | 17.5 µs per file (1.75 s per 100k files). `getattrlistbulk` can't return them | Load tags lazily (§5.4) |
| S2 | Does `searchfs` work on APFS? | Yes, on APFS and HFS+. It reports normal user-facing paths, so firmlinks aren't a problem. Matching is case-insensitive. But a whole-volume scan of the Data volume takes **65 s** | **Drop the Catalog backend** (§5.6) |
| S3 | Can we tell whether a folder is Spotlight-indexed? | Not reliably. Per-folder probes gave contradictory answers. Spotlight even answered queries on an unindexed disk image, and new files took 0.2–2.6 s to appear in the index | **Drop IndexProbe.** Folder name searches always run Crawl alongside Spotlight (§5.6) |
| S4 | Does `trashItem` record Put Back information? | **Yes.** `FileManager.trashItem` updated `~/.Trash/.DS_Store` with a `ptbL` (put-back location) record for the file, the same record Finder writes. No xattrs are added to the trashed item. Run from Terminal.app with Full Disk Access | Finder can Put Back items RealFinder trashes. RealFinder can Put Back items Finder trashed by reading `ptbL`/`ptbN`. Showing the Trash at all requires Full Disk Access (§5.7, §5.11) |
| S5 | How do tags and the tag catalog work? | The API writes `Name\n<color>` and also updates the FinderInfo label. Writing the raw xattr does **not** update FinderInfo, which leaves `labelNumber` stale. Finder's sidebar list is `FavoriteTagNames` in `com.apple.finder` and is readable. The full catalog syncs through iCloud and isn't readable from here | Write tags only through the API. Discover the catalog; never write it (§5.8) |
| S6 | Can comments interoperate with Finder? | One way only. Finder **ignores** a comment written only as the `kMDItemFinderComment` xattr (Get Info shows nothing). When Finder sets a comment through Apple Events, it **also** updates the xattr | Read comments from the xattr. Write them through Apple Events to Finder, which needs the Automation permission, and also write the xattr. Without permission, write the xattr only and tell the user Finder won't show it (§5.8) |
| S7 | Do thumbnails download cloud files? | **No.** A dataless iCloud Drive file returned a real thumbnail (type 2) and was still dataless afterward. It took ~2 s, presumably fetched from the provider. Local files take ~0.3 s cold. Apps fail with `.thumbnail` alone | Request `[.icon, .thumbnail]` for every item, cloud or not. Show the type icon right away while cloud thumbnails load. Previews (Quick Look) of cloud files are still untested |
| S8 | Does `NSFileViewer` work for "Show in Finder"? | **Deferred.** `NSFileViewer` is currently unset. Testing means changing a global preference, so it waits for your OK | — |
| — | Are the kind categories correct (§3.2)? | 5 mismatches in a 57-sample corpus, now 0. See notes below | Rules refined (§3.2) |

## Notes

### S1: enumeration (median of 5 runs; files are 64-byte files plus 2% folders, in a flat directory)

| Entries | getattrlistbulk | + UTType (memoized) | FileManager, 4 keys | FileManager, 16 `FileItem` keys |
|---|---|---|---|---|
| 1,000 | 3.4 ms | 6.5 ms | 38 ms | 322 ms |
| 10,000 | 35 ms | 49 ms | 233 ms | 2,958 ms |
| 100,000 | 182 ms | 272 ms | 1,288 ms | **18,173 ms** |

The "+ UTType" column computes each item's type from its extension, memoized. That is what production needs for `contentType`.

Packages and hidden items need no extra syscalls:
- **Packages:** directories whose type conforms to `com.apple.package` (memoized per extension), plus the FinderInfo bundle bit.
- **Hidden:** the `UF_HIDDEN` flag or a leading dot.

### S1b/c: sort keys

**Key format:**
- Names are folded for case, diacritics and width.
- ASCII punctuation gets ICU root-collation weights, which sort before digits.
- Each run of digits is encoded as `(marker, length, digits)`, so byte order equals numeric order.
- When two keys are equal (names that differ only in case or accents), `localizedStandardCompare` breaks the tie.

**Remaining work for M1:**
- Non-ASCII symbols and punctuation (`•`, `–`, `©` and so on) must sort with ASCII punctuation.
- Non-Latin scripts should fall back to the real comparator.
- Build a regression corpus that includes CJK, Cyrillic and emoji names.

### S2: `searchfs`

| Volume | Matches | Time |
|---|---|---|
| `/` (sealed system volume) | 8,776 | 4.7 s |
| `/System/Volumes/Data` | 1 | 65 s |
| HFS+ disk image | 1 | 0.11 s |

The data-volume search found `fixtures/rfneedle-zq7.txt` and returned its path as `/Users/mke/…`, with no `/System/Volumes/Data` prefix.

That speed is useless for interactive search. For "This Mac + include system & hidden files", use Spotlight results plus a clearly labeled, low-priority exhaustive crawl.

### S3: index probes

| Probe | Result |
|---|---|
| A. `mdutil -s` | Correct, but only per volume |
| B. Find the folder's own name in its parent | False negative for `~/Library/Caches`, even though new files there were indexed in 0.2–0.7 s |
| C. Create a file and wait for it to be indexed | Accurate, but needs write access and takes seconds |
| D. "Any item inside" | Said "yes" for an unindexed DMG and "no" for indexed `/usr/lib` |

**Conclusion:** stop trying to predict Spotlight's coverage. Treat Spotlight as fast and possibly incomplete, and Crawl plus FSEvents as authoritative.

### Kind categories

What the system's types revealed, and how the rules changed:

- **`.svg` conforms to `public.xml`.** Code now excludes `public.image`.
- **`.js` conforms to `public.executable`** (and `public.script`). Programs is now apps plus `public.unix-executable` plus the executable bit. It no longer includes `.script` or `.executable`, so a script is a program only when it's executable.
- **`.mkv`, `.rar`, `.rs`, `.go` and `.woff2` are dynamic types** unless some installed app declares them. Every category needs an extension list as well as conformance.
- **`.ts` is MPEG-2 transport stream to the system.** It matches both Video and Code. This ambiguity is accepted, and users can edit the categories.
