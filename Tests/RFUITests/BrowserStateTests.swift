import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

/// Acceptance tests for headline requirement 3 (DESIGN.md §3.3, §8): switching view modes never
/// changes the order, never reloads and never re-sorts.
@MainActor
@Suite(.serialized) struct BrowserStateTests {
    let folder: URL
    let storeDir: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rf-ui-tests-\(UUID().uuidString)")
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
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Waits until no new snapshot has arrived for 400 ms (setup's own FSEvents can trigger a
    /// legitimate reload shortly after the first load).
    private func quiesce(_ state: BrowserState) async {
        var last = state.snapshot.generation
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(5)
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
