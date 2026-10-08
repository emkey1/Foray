import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import RFModel

// MARK: - Fixtures

private let nextInode = Atomic<UInt64>(1)

private func item(
    _ name: String, dir: Bool = false, type: UTType? = nil, size: Int64? = 100, modified: Date? = nil,
    hidden: Bool = false, executable: Bool = false
) -> FileItem {
    let inode = nextInode.add(1, ordering: .relaxed).newValue
    let ext = (name as NSString).pathExtension
    var flags: ItemFlags = []
    if dir { flags.insert(.directory) }
    if hidden { flags.insert(.hidden) }
    if executable { flags.insert(.executable) }
    return FileItem(
        id: FileID(device: 1, inode: inode), url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
        contentType: type ?? (dir ? .folder : UTType(filenameExtension: ext) ?? .data), flags: flags,
        size: dir ? nil : size, modified: modified)
}

private let finderOrder: @Sendable (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }

// MARK: - Natural sort key

@Suite struct NaturalSortKeyTests {
    static let corpus = [
        "file 10.txt", "file 2.txt", "File 1.txt", "file 01.txt", "file1.txt", "Report", "report", "Résumé",
        "resume", "_draft", "(copy)", "#hash", "Zeta", "alpha", "IMG_0002.jpg", "IMG_10.jpg", "img 3.jpg",
        "• Bullet", "– dash", "© notice", "Ünïcode", "Ölfass", "ørsted", "Ελληνικά", "日本語", "Русский",
        "😀 emoji", "a.b", "a b", "a-b", "a_b", "", "007", "7", "v1.10.2", "v1.9.12", "x".padding(toLength: 300, withPad: "y", startingAt: 0),
    ]

    @Test func matchesFinderOrderExactly() {
        let reference = Self.corpus.sorted(by: finderOrder)
        let keyed = Self.corpus.map(NaturalSortKey.init).sorted().map(\.original)
        let inversions = zip(keyed, keyed.dropFirst()).filter { finderOrder($1, $0) }.map { "\($0.0) > \($0.1)" }
        #expect(keyed == reference, "out of Finder order: \(inversions)")
    }

    @Test func numericRunsCompareNumerically() {
        #expect(NaturalSortKey("file 2") < NaturalSortKey("file 10"))
        #expect(NaturalSortKey("v1.9") < NaturalSortKey("v1.10"))
    }

    @Test func nonLatinNamesFallBackToCollator() {
        #expect(!NaturalSortKey("日本語").exact)
        #expect(NaturalSortKey("Résumé").exact)   // folds to ASCII
        #expect(!NaturalSortKey("• Bullet").exact)
    }
}

// MARK: - Arrangement mutations

@Suite struct ArrangementTests {
    @Test func headerClickSetsPrimaryThenReverses() {
        var a = Arrangement()
        a.setPrimary(.dateModified)
        #expect(a.primary == SortDescriptor(.dateModified, ascending: false))  // newest first, like Finder
        #expect(a.sort.map(\.key) == [.dateModified, .name])
        a.setPrimary(.dateModified)
        #expect(a.primary.ascending)
    }

    @Test func shiftClickAddsSecondaryWithoutTouchingPrimary() {
        var a = Arrangement(sort: [SortDescriptor(.kind)])
        a.toggleSecondary(.size)
        #expect(a.sort.map(\.key) == [.kind, .size])
        a.toggleSecondary(.size)
        #expect(a.sort[1].ascending)  // size starts descending; toggled to ascending
        a.toggleSecondary(.kind)  // primary: ignored
        #expect(a.sort.map(\.key) == [.kind, .size])
    }

    @Test func sortKeyCountIsBounded() {
        var a = Arrangement()
        for k in [SortKey.size, .kind, .dateAdded, .dateCreated] { a.toggleSecondary(k) }
        #expect(a.sort.count == Arrangement.maxSortKeys)
        #expect(a.primary.key == .name)
    }
}

// MARK: - Engine

@Suite struct ArrangementEngineTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func filtersHiddenUnlessShown() {
        let items = [item("a"), item(".hidden", hidden: true)]
        #expect(ArrangementEngine.arrange(items, with: Arrangement()).items.map(\.name) == ["a"])
        #expect(ArrangementEngine.arrange(items, with: Arrangement(showHidden: true)).items.count == 2)
    }

    @Test func foldersFirstAppliesBeforeSort() {
        let items = [item("b.txt"), item("z", dir: true), item("a.txt")]
        let snap = ArrangementEngine.arrange(items, with: Arrangement(foldersFirst: true))
        #expect(snap.items.map(\.name) == ["z", "a.txt", "b.txt"])
    }

    @Test func missingValuesSortLastInBothDirections() {
        let items = [item("folder", dir: true), item("big", size: 900), item("small", size: 1)]
        let desc = ArrangementEngine.arrange(items, with: Arrangement(sort: [SortDescriptor(.size, ascending: false)]))
        let asc = ArrangementEngine.arrange(items, with: Arrangement(sort: [SortDescriptor(.size, ascending: true)]))
        #expect(desc.items.map(\.name) == ["big", "small", "folder"])
        #expect(asc.items.map(\.name) == ["small", "big", "folder"])
    }

    @Test func secondaryKeyBreaksTies() {
        let items = [item("b.txt", size: 5), item("a.txt", size: 5), item("c.txt", size: 9)]
        let a = Arrangement(sort: [SortDescriptor(.size, ascending: true), SortDescriptor(.name, ascending: false)])
        #expect(ArrangementEngine.arrange(items, with: a).items.map(\.name) == ["b.txt", "a.txt", "c.txt"])
    }

    @Test func orderIsTotalAndDeterministic() {
        // Same name and size: FileID decides, so repeated arrangements never shuffle.
        let items = (0..<50).map { _ in item("same", size: 1) }
        let first = ArrangementEngine.arrange(items.shuffled(), with: Arrangement()).items.map(\.id)
        let second = ArrangementEngine.arrange(items.shuffled(), with: Arrangement()).items.map(\.id)
        #expect(first == second)
    }

    @Test func groupsByDateNewestFirstAndSortsWithin() {
        let day: TimeInterval = 86_400
        let items = [
            item("old", modified: now - 400 * day), item("today2", modified: now - 60),
            item("today1", modified: now - 120), item("week", modified: now - 3 * day), item("never"),
        ]
        let snap = ArrangementEngine.arrange(
            items, with: Arrangement(groupBy: .dateModified), now: now, calendar: Calendar(identifier: .gregorian))
        #expect(snap.groups.map(\.title).first == "Today")
        #expect(snap.groups.map(\.title).last == "Unknown")
        #expect(snap.groups.map(\.title).contains("Previous 7 Days"))
        let today = snap.groups[0].range.map { snap.items[$0].name }
        #expect(today == ["today1", "today2"])
    }

    @Test func kindFilter() {
        let items = [item("a.jpg"), item("b.pdf"), item("c.swift"), item("d", dir: true)]
        let images = ArrangementEngine.arrange(items, with: Arrangement(kindFilter: ["images"]))
        #expect(images.items.map(\.name) == ["a.jpg"])
        let docsOrCode = ArrangementEngine.arrange(items, with: Arrangement(kindFilter: ["documents", "code"]))
        #expect(docsOrCode.items.map(\.name) == ["b.pdf", "c.swift"])
    }

    @Test func snapshotIndexLookup() {
        let items = [item("b"), item("a")]
        let snap = ArrangementEngine.arrange(items, with: Arrangement())
        #expect(snap.index(of: items[0].id) == 1)
        #expect(snap.item(items[1].id)?.name == "a")
    }
}

// MARK: - Kinds (rules validated in M0)

@Suite struct KindCategoryTests {
    let catalog = KindCatalog()

    @Test(arguments: [
        ("x.pdf", ["documents", "pdfs"]), ("x.md", ["documents"]), ("x.svg", ["images"]), ("x.js", ["code"]),
        ("x.ts", ["code", "video"]), ("x.mkv", ["video"]), ("x.woff2", ["fonts"]), ("x.rar", ["archives"]),
        ("x.dmg", ["archives"]), ("x.sh", ["code"]), ("x.go", ["code"]), ("x.heic", ["images"]),
    ])
    func builtInCategories(name: String, expected: [String]) {
        #expect(catalog.categories(of: item(name)) == Set(expected))
    }

    @Test func executablesArePrograms() {
        #expect(catalog.categories(of: item("run.sh", executable: true)) == ["code", "programs"])
        #expect(catalog.categories(of: item("tool", type: .unixExecutable)).contains("programs"))
        #expect(catalog.categories(of: item("Safari.app", type: .applicationBundle)).contains("programs"))
    }

    @Test func foldersButNotPackages() {
        #expect(catalog.categories(of: item("dir", dir: true)) == ["folders"])
        #expect(!catalog.categories(of: item("x.app", dir: true, type: .applicationBundle)).contains("folders"))
    }
}

// MARK: - Navigation and settings

@Suite struct NavigationTests {
    let a = Location.folder(URL(fileURLWithPath: "/a")), b = Location.folder(URL(fileURLWithPath: "/b"))
    let c = Location.folder(URL(fileURLWithPath: "/c"))

    @Test func backForward() {
        var h = NavigationHistory(a)
        h.visit(b)
        h.visit(c)
        #expect(h.goBack()?.location == b)
        #expect(h.goBack()?.location == a)
        #expect(!h.canGoBack)
        #expect(h.goForward()?.location == b)
        h.visit(a)
        #expect(!h.canGoForward)
    }

    @Test func departingSelectionIsRemembered() {
        var h = NavigationHistory(a)
        h.visit(b, leaving: HistoryEntry(location: a, selectedNames: ["x"]))
        #expect(h.goBack()?.selectedNames == ["x"])
    }
}

@Suite struct SettingsTests {
    let folder = FolderKey(volumeUUID: "V", fileID: 42, path: "/Users/me/Projects")

    @Test func sameEverywhereUpdatesClassDefault() {
        var db = ViewSettingsDatabase()
        var s = ViewSettings()
        s.presentation.mode = .list
        #expect(db.update(s, cls: .folder, folder: folder) == .classDefault(.folder))
        let other = FolderKey(volumeUUID: "V", fileID: 7, path: "/elsewhere")
        #expect(db.resolve(.folder, folder: other).0.presentation.mode == .list)
    }

    @Test func pinnedFolderKeepsItsOwnSettingsAcrossRename() {
        var db = ViewSettingsDatabase()
        var pinned = ViewSettings()
        pinned.arrangement.setPrimary(.size)
        db.pin(pinned, folder: folder)
        let renamed = FolderKey(volumeUUID: "V", fileID: 42, path: "/Users/me/Renamed")
        #expect(db.resolve(.folder, folder: renamed).0.arrangement.primary.key == .size)
        #expect(db.resolve(.folder, folder: renamed).1 == .folder(folder))
        db.unpin(renamed)
        #expect(db.resolve(.folder, folder: folder).1 == .classDefault(.folder))
    }

    @Test func perFolderModelCreatesOverrides() {
        var db = ViewSettingsDatabase()
        db.model = .perFolder
        var s = ViewSettings()
        s.presentation.mode = .list
        db.update(s, cls: .folder, folder: folder)
        #expect(db.resolve(.folder, folder: FolderKey(volumeUUID: "V", fileID: 9, path: "/x")).0.presentation.mode == .icon)
    }

    @Test func searchResultsDefaultToList() {
        #expect(ViewSettingsDatabase().resolve(.searchResults, folder: nil).0.presentation.mode == .list)
    }

    @Test func roundTripsThroughJSON() throws {
        var db = ViewSettingsDatabase()
        db.pin(ViewSettings(arrangement: Arrangement(groupBy: .kind)), folder: folder)
        let data = try JSONEncoder().encode(db)
        let back = try JSONDecoder().decode(ViewSettingsDatabase.self, from: data)
        #expect(back.resolve(.folder, folder: folder).0.arrangement.groupBy == .kind)
    }
}

@Suite struct SortPlanEquivalenceTests {
    /// The precomputed-column sort must give exactly the comparator's order.
    typealias SD = RFModel.SortDescriptor
    static let cases: [[SD]] = [
        [SD(.name)], [SD(.size)], [SD(.size, ascending: true)], [SD(.kind), SD(.dateModified)],
        [SD(.dateModified, ascending: true)], [SD(.fileExtension), SD(.name, ascending: false)], [SD(.folder)],
        [SD(.dateCreated), SD(.size), SD(.kind)],
    ]

    @Test(arguments: cases)
    func matchesComparator(sort: [SD]) {
        let names = ["report", "Report", "résumé", "file 2", "file 10", "IMG_0001", "notes", "日本", "• x", "a b", "a_b"]
        let exts = ["txt", "jpg", "pdf", "", "swift", "md"]
        var items: [FileItem] = []
        for i in 0..<600 {
            let dir = i % 9 == 0
            let name = names[i % names.count] + " \(i % 37)" + (dir ? "" : "." + exts[i % exts.count])
            let date = i % 13 == 0 ? nil : Date(timeIntervalSince1970: Double((i * 7919) % 1000) * 3600)
            items.append(FileItem(
                id: FileID(device: 1, inode: UInt64(10_000 + i)), url: URL(fileURLWithPath: "/d\(i % 4)/\(name)"),
                name: name, contentType: dir ? .folder : (UTType(filenameExtension: exts[i % exts.count]) ?? .data),
                flags: dir ? .directory : [], size: dir ? nil : Int64((i * 31) % 50), created: date, modified: date))
        }
        for foldersFirst in [false, true] {
            let a = Arrangement(sort: sort, foldersFirst: foldersFirst)
            let expected = items.sorted(by: ArrangementEngine.comparator(for: a)).map(\.id)
            let actual = ArrangementEngine.arrange(items.shuffled(), with: a).items.map(\.id)
            #expect(actual == expected)
        }
    }
}
