import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

/// Nested in UISerial: these tests swap shared singletons (AppModel.shared, OperationCenter.shared),
/// so they must not run in parallel with each other.
extension UISerial {
    /// Acceptance tests for headline requirement 3 (DESIGN.md §3.3, §8): switching view modes never
    /// changes the order, never reloads and never re-sorts.
    @MainActor
    @Suite(.serialized) final class BrowserStateTests {
        let base = TestDirs.make("ui-tests")
        let folder: URL
        let storeDir: URL

        deinit { try? FileManager.default.removeItem(at: base) }

        init() throws {
            folder = base.appendingPathComponent("folder", isDirectory: true)
            storeDir = base.appendingPathComponent("store", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Names, sizes and dates that each produce a different order.
            let specs: [(String, Int, TimeInterval)] = [
                ("b.txt", 300, -50), ("a.pdf", 10, -10), ("c.jpg", 2_000, -500), ("file 10.md", 1, -5),
                ("file 2.md", 50, -100), ("Zeta.swift", 900, -1),
            ]
            for (name, size, age) in specs {
                let url = folder.appendingPathComponent(name)
                FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 65, count: size))
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: url.path)
            }
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
            AppModel.shared = AppModel(store: AppSupportStore(directory: storeDir))
        }

        private func settle(_ state: BrowserState, until condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }

        /// Waits until no new snapshot has arrived for 400 ms (setup's own FSEvents can trigger a
        /// legitimate reload shortly after the first load).
        private func quiesce(_ state: BrowserState) async {
            var last = state.snapshot.generation
            var stableSince = Date()
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(25))
                if state.snapshot.generation != last {
                    last = state.snapshot.generation
                    stableSince = Date()
                } else if Date().timeIntervalSince(stableSince) > 0.4 {
                    return
                }
            }
        }

        private func loaded(_ location: Location) async -> BrowserState {
            let state = BrowserState(location: location)
            await settle(state) { state.loadState == .complete && state.snapshot.items.count == 7 }
            return state
        }

        @Test(arguments: [SortKey.name, .size, .dateModified, .kind, .fileExtension])
        func switchingModesKeepsOrderWithoutResorting(key: SortKey) async throws {
            let state = await loaded(.folder(folder))
            defer { state.invalidate() }
            await quiesce(state)
            state.updateArrangement { $0.setPrimary(key) }
            await quiesce(state)
            let order = state.snapshot.items.map(\.name)
            let arrangement = state.settings.arrangement
            // Late FSEvents from this test's own setup can legitimately reload the folder, so count
            // arrangements caused by settings changes rather than snapshot generations.
            let settingsArrangements = state.rearrangeLog.filter { $0 == "settings" }.count

            for mode in ViewMode.allCases + [.icon, .list] {
                state.updatePresentation { $0.mode = mode }
                try await Task.sleep(for: .milliseconds(30))
                #expect(state.settings.presentation.mode == mode)
                #expect(state.settings.arrangement == arrangement)
                #expect(state.rearrangeLog.filter { $0 == "settings" }.count == settingsArrangements,
                        "mode switch must not re-arrange (\(mode)): \(state.rearrangeLog)")
                #expect(state.snapshot.items.map(\.name) == order, "\(state.snapshot.items.map(\.name)) vs \(order)")
            }
        }

        @Test func selectionSurvivesModeSwitch() async throws {
            let state = await loaded(.folder(folder))
            defer { state.invalidate() }
            let picked = Set(state.snapshot.items.prefix(2).map(\.id))
            state.setSelection(picked, anchor: state.snapshot.items[1].id)
            state.updatePresentation { $0.mode = .list }
            state.updatePresentation { $0.mode = .icon }
            #expect(state.selection == picked)
            #expect(state.focusAnchor == state.snapshot.items[1].id)
        }

        @Test func sortChangeKeepsSelection() async throws {
            let state = await loaded(.folder(folder))
            defer { state.invalidate() }
            let target = try #require(state.snapshot.items.first { $0.name == "c.jpg" })
            state.setSelection([target.id], anchor: target.id)
            state.updateArrangement { $0.setPrimary(.size) }
            await settle(state) { state.snapshot.items.first?.name == "c.jpg" }
            #expect(state.snapshot.items.first?.name == "c.jpg")  // largest first
            #expect(state.selection == [target.id])
        }

        @Test func newTabOnSameKindOfLocationGetsTheSameArrangement() async throws {
            let first = await loaded(.folder(folder))
            defer { first.invalidate() }
            first.updateArrangement { $0.setPrimary(.dateModified) }
            first.updatePresentation { $0.mode = .list }
            let second = await loaded(.folder(folder.appendingPathComponent("..").standardizedFileURL))
            defer { second.invalidate() }
            await settle(second) { second.settings.presentation.mode == .list }
            #expect(second.settings.arrangement.primary.key == .dateModified)
            #expect(second.settings.presentation.mode == .list)
        }

        @Test func pinnedFolderKeepsItsOwnSettings() async throws {
            let state = await loaded(.folder(folder))
            defer { state.invalidate() }
            await settle(state) { state.details.folderKey != nil }
            state.updateArrangement { $0.setPrimary(.size) }
            state.togglePin()
            #expect(state.isPinned)
            state.updateArrangement { $0.setPrimary(.kind) }   // edits the pinned settings
            let other = await loaded(.folder(folder.deletingLastPathComponent()))
            defer { other.invalidate() }
            #expect(other.settings.arrangement.primary.key == .size)  // class default stayed at size
            #expect(state.settings.arrangement.primary.key == .kind)
        }

        @Test func goingBackRestoresSelection() async throws {
            let state = await loaded(.folder(folder))
            defer { state.invalidate() }
            let sub = try #require(state.snapshot.items.first { $0.name == "sub" })
            state.setSelection([sub.id], anchor: sub.id)
            state.navigate(to: .folder(sub.url))
            await settle(state) { state.loadState == .complete && state.location == .folder(sub.url) }
            state.goBack()
            await settle(state) { state.loadState == .complete && !state.selection.isEmpty }
            #expect(state.selectedItems.map(\.name) == ["sub"])
        }

        @Test func enclosingFolderSelectsWhereWeCameFrom() async throws {
            let state = await loaded(.folder(folder.appendingPathComponent("sub")))
            defer { state.invalidate() }
            await settle(state) { !state.details.pathChain.isEmpty }
            state.goEnclosing()
            await settle(state) { state.loadState == .complete && !state.selection.isEmpty }
            #expect(state.selectedItems.map(\.name) == ["sub"])
        }
    }

    /// Search flow (DESIGN.md §3.1): scope defaults to the current folder, refining doesn't add
    /// history, and ending the search restores the folder and its selection.
    @MainActor
    @Suite(.serialized) final class SearchFlowTests {
        let base = TestDirs.make("searchflow")
        let folder: URL

        deinit { try? FileManager.default.removeItem(at: base) }

        init() throws {
            folder = base.appendingPathComponent("Projects", isDirectory: true)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("deep/er"), withIntermediateDirectories: true)
            for path in ["report.pdf", "deep/report notes.txt", "deep/er/photo report.jpg", "unrelated.txt"] {
                FileManager.default.createFile(atPath: folder.appendingPathComponent(path).path, contents: Data("x".utf8))
            }
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
        }

        private func wait(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }

        @Test func searchDefaultsToCurrentFolderAndReturns() async throws {
            let state = BrowserState(location: .folder(folder))
            defer { state.invalidate() }
            await wait { state.loadState == .complete && state.snapshot.items.count == 3 }
            let unrelated = try #require(state.snapshot.items.first { $0.name == "unrelated.txt" })
            state.setSelection([unrelated.id], anchor: unrelated.id)

            state.search("report")
            let q = try #require(state.location.searchQuery)
            #expect(q.scope == .folder(folder, recursive: true))
            #expect(q.origin == folder)
            await wait { state.loadState == .complete && state.snapshot.items.count == 3 }
            #expect(Set(state.snapshot.items.map(\.name)) == ["report.pdf", "report notes.txt", "photo report.jpg"],
                    "got \(state.snapshot.items.map(\.url.path)) state=\(state.loadState) status=\(String(describing: state.searchStatus.map { ($0.items.count, $0.crawlRunning, $0.spotlightRunning) }))")
            #expect(state.settings.presentation.mode == .list)  // search results class default

            state.search("report kind:images")       // refine: replaces, doesn't add history
            await wait { state.loadState == .complete && state.snapshot.items.count == 1 }
            #expect(state.snapshot.items.map(\.name) == ["photo report.jpg"])
            state.updateSearch { $0.scope = .folder(folder, recursive: false) }   // Subfolders off
            await wait { state.loadState == .complete && state.snapshot.items.isEmpty }
            #expect(state.snapshot.items.isEmpty)

            state.endSearch()
            #expect(state.location == .folder(folder))
            #expect(!state.history.canGoBack)
            await wait { state.loadState == .complete && !state.selection.isEmpty }
            #expect(state.selectedItems.map(\.name) == ["unrelated.txt"])
        }

        @Test func clearingTheFieldEndsTheSearch() async throws {
            let state = BrowserState(location: .folder(folder))
            defer { state.invalidate() }
            state.search("report")
            #expect(state.location.searchQuery != nil)
            state.search("   ")
            #expect(state.location == .folder(folder))
        }

        @Test func searchFollowsFolderChangesButNotOpeningResults() async throws {
            let saved = BrowserState.searchFollowsFolderChanges
            defer { BrowserState.searchFollowsFolderChanges = saved }
            BrowserState.searchFollowsFolderChanges = true
            let deep = folder.appendingPathComponent("deep")
            let state = BrowserState(location: .folder(folder))
            defer { state.invalidate() }
            state.search("report")
            state.jump(to: .folder(deep))                   // e.g. a sidebar click
            let q = try #require(state.location.searchQuery)
            #expect(q.text == "report")
            #expect(q.scope == .folder(deep, recursive: true))
            await wait { state.loadState == .complete && state.snapshot.items.count == 2 }
            #expect(Set(state.snapshot.items.map(\.name)) == ["report notes.txt", "photo report.jpg"])

            state.goEnclosing()                             // ⌘↑ searches the parent of the origin
            #expect(state.location.searchQuery?.scope == .folder(folder, recursive: true))

            state.navigate(to: .folder(deep))               // opening a result shows the folder
            #expect(state.location == .folder(deep))
            state.goBack()
            #expect(state.location.searchQuery?.text == "report")

            BrowserState.searchFollowsFolderChanges = false
            state.jump(to: .folder(deep))
            #expect(state.location == .folder(deep))
        }

        @Test func searchFromComputerSearchesThisMac() {
            let state = BrowserState(location: .computer)
            defer { state.invalidate() }
            #expect(state.defaultSearchScope == .thisMac)
        }
    }

    /// Regression: a sort of the previous folder that finished after navigating was shown as the new
    /// location's contents (search results briefly showed the folder's items).
    @MainActor
    @Suite(.serialized) final class StaleSnapshotTests {
        let base = TestDirs.make("stale")

        deinit { try? FileManager.default.removeItem(at: base) }

        @Test func navigatingDiscardsArrangementsForThePreviousLocation() async throws {
            let big = base.appendingPathComponent("big"), small = base.appendingPathComponent("small")
            for dir in [big, small] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            for i in 0..<8_000 { FileManager.default.createFile(atPath: big.appendingPathComponent("f\(i)").path, contents: nil) }
            FileManager.default.createFile(atPath: small.appendingPathComponent("only.txt").path, contents: nil)
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            for _ in 0..<5 {
                let state = BrowserState(location: .folder(big))
                // Navigate away while the big folder is still loading and sorting.
                try await Task.sleep(for: .milliseconds(30))
                state.navigate(to: .folder(small))
                var sawForeign = false
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline {
                    if state.snapshot.items.contains(where: { $0.name != "only.txt" }) { sawForeign = true }
                    try await Task.sleep(for: .milliseconds(2))
                }
                #expect(!sawForeign)
                #expect(state.snapshot.items.map(\.name) == ["only.txt"])
                state.invalidate()
            }
        }
    }
}
