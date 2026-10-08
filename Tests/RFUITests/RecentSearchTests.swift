import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

@MainActor
@Suite(.serialized) final class RecentSearchTests {
    let base = TestDirs.make("recents")
    let folder: URL

    deinit { try? FileManager.default.removeItem(at: base) }

    init() throws {
        folder = base.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("report.pdf").path, contents: nil)
        AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
    }

    private func q(_ text: String, _ scope: SearchScope? = nil) -> SearchQuery {
        SearchQuery(text: text, scope: scope ?? .folder(folder, recursive: true))
    }

    @Test func keepsTheLastDozenMostRecentFirstWithoutDuplicates() {
        let m = AppModel.shared
        for i in 0..<15 { m.recordSearch(q("search \(i)")) }
        #expect(m.recentSearches.count == 12)
        #expect(m.recentSearches.first?.text == "search 14")
        m.recordSearch(q("search 10"))                      // re-running moves it to the top
        #expect(m.recentSearches.first?.text == "search 10")
        #expect(m.recentSearches.filter { $0.text == "search 10" }.count == 1)
        m.recordSearch(q("search 10", .thisMac))            // same text, different scope: separate entry
        #expect(m.recentSearches.prefix(2).map(\.scope) == [.thisMac, .folder(folder, recursive: true)])
        let reloaded = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
        #expect(reloaded.recentSearches.map(\.text) == m.recentSearches.map(\.text))
        m.clearRecentSearches()
        #expect(m.recentSearches.isEmpty)
    }

    @Test func recordedWhenLeavingNotWhileTyping() {
        let state = BrowserState(location: .folder(folder))
        defer { state.invalidate() }
        state.search("r")
        state.search("re")
        state.search("report")                                 // refining: nothing recorded yet
        #expect(AppModel.shared.recentSearches.isEmpty)
        state.endSearch()                                      // Escape
        #expect(AppModel.shared.recentSearches.map(\.text) == ["report"])
        state.search("pdf")
        state.navigate(to: .computer)                          // going elsewhere
        #expect(AppModel.shared.recentSearches.map(\.text) == ["pdf", "report"])
    }

    @Test func runningARecentSearchUsesItsSavedScope() {
        let state = BrowserState(location: .computer)
        defer { state.invalidate() }
        let saved = SearchQuery(text: "report", scope: .folder(folder, recursive: false), match: .namesAndContents)
        state.runSearch(saved)
        #expect(state.location.searchQuery == saved)
    }

    /// Restored search tabs open on their folder with the search waiting, not running.
    @Test func restoredSearchTabsDontRun() {
        _ = NSApplication.shared
        let saved = q("report kind:pdfs")
        AppModel.shared.saveSession(AppModel.Session(windows: [.init(tabs: [.search(saved)], selectedTab: 0, frame: nil)]))
        let manager = WindowManager()
        #expect(manager.restoreSession())
        let c = manager.controllersForTesting[0]
        defer { c.window?.close() }
        #expect(c.browser.state.location == .folder(folder))
        #expect(c.browser.state.searchStatus == nil)
        #expect(c.pendingSearch == saved)
        #expect(AppModel.shared.recentSearches.first == saved)
        // Still waiting after another save/restore cycle.
        manager.prepareForTermination()
        #expect(AppModel.shared.loadSession()?.windows.first?.tabs.first == .search(saved))
    }

    @Test func mostRecentSearchIsPrefilledAtLaunch() {
        _ = NSApplication.shared
        AppModel.shared.recordSearch(q("invoice"))
        let manager = WindowManager()
        manager.openWindow(.folder(folder))
        manager.prefillMostRecentSearch()
        let c = manager.controllersForTesting[0]
        defer { c.window?.close() }
        #expect(c.pendingSearch?.text == "invoice")
        #expect(c.browser.state.location == .folder(folder))   // not running
    }
}
