import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

/// DESIGN.md §5.13 budgets, measured through the real browser (BrowserState + view controllers in
/// an offscreen window). Opt-in because building the 100k fixture takes a while the first time:
///   RF_PERF=1 swift test --filter PerformanceBudgetTests
@MainActor
@Suite(.serialized, .disabled(if: ProcessInfo.processInfo.environment["RF_PERF"] == nil))
struct PerformanceBudgetTests {
    /// 110k files, kept between runs because they're slow to create. Delete with:
    ///   rm -rf "$TMPDIR/rf-perf-fixtures"
    nonisolated static let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("rf-perf-fixtures")

    static func fixture(_ count: Int) throws -> URL {
        let dir = fixtures.appendingPathComponent("flat-\(count)")
        if (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) == count { return dir }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exts = ["txt", "jpg", "png", "pdf", "swift", "zip", "mov", "md", "json", ""]
        for i in 0..<count {
            let ext = exts[i % exts.count]
            if i % 50 == 0 {
                try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder \(i)"), withIntermediateDirectories: false)
            } else {
                FileManager.default.createFile(atPath: dir.appendingPathComponent("file \(i)" + (ext.isEmpty ? "" : ".\(ext)")).path,
                                               contents: Data(repeating: 65, count: i % 997))
            }
        }
        return dir
    }

    private func ms(since t0: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }

    private func wait(_ timeout: Double = 30, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }

    private func report(_ name: String, _ value: Double, budget: Double) {
        print(String(format: "BUDGET %-44@ %8.1f ms  (budget %6.0f ms) %@", name as NSString, value, budget,
                     value <= budget ? "ok" : "OVER"))
        #expect(value <= budget, "\(name): \(value) ms > \(budget) ms")
    }

    @Test(arguments: [(1_000, 50.0, 50.0), (10_000, 100.0, 400.0), (100_000, 150.0, 3_000.0)])
    func openFolder(count: Int, firstBudget: Double, fullBudget: Double) async throws {
        let dir = try Self.fixture(count)
        AppModel.shared = AppModel(store: AppSupportStore(directory: Self.fixtures.appendingPathComponent("store-\(UUID().uuidString)")))
        _ = try await DirectoryLoader.shared.loadAll(dir)  // warm the disk cache, like a revisit
        let t0 = DispatchTime.now().uptimeNanoseconds
        let state = BrowserState(location: .folder(dir))
        defer { state.invalidate() }
        await wait { !state.snapshot.items.isEmpty }
        let first = ms(since: t0)
        await wait { state.loadState == .complete && state.snapshot.items.count == count }
        let full = ms(since: t0)
        report("open \(count): first items", first, budget: firstBudget)
        report("open \(count): complete", full, budget: fullBudget)
    }

    @Test(arguments: [10_000, 100_000])
    func switchViewModes(count: Int) async throws {
        let dir = try Self.fixture(count)
        AppModel.shared = AppModel(store: AppSupportStore(directory: Self.fixtures.appendingPathComponent("store-\(UUID().uuidString)")))
        let browser = BrowserViewController(location: .folder(dir))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 1000, height: 700))
        defer { browser.state.invalidate() }
        await wait { browser.state.loadState == .complete && browser.state.snapshot.items.count == count }
        // A person doesn't switch views within half a second of opening a folder; by then the other
        // view has been built in the background (prewarmOtherMode).
        try await Task.sleep(for: .milliseconds(500))
        var worst = 0.0
        for mode in [ViewMode.list, .icon, .list, .icon] {
            let t0 = DispatchTime.now().uptimeNanoseconds
            browser.state.updatePresentation { $0.mode = mode }
            let t1 = DispatchTime.now().uptimeNanoseconds
            window.layoutIfNeeded()
            let t2 = DispatchTime.now().uptimeNanoseconds
            window.contentView?.displayIfNeeded()
            let elapsed = ms(since: t0)
            print(String(format: "SWITCH %d items → %@: %.1f ms (update %.1f, layout %.1f, display %.1f)", count, mode.rawValue, elapsed,
                         Double(t1 - t0) / 1e6, Double(t2 - t1) / 1e6, Double(DispatchTime.now().uptimeNanoseconds - t2) / 1e6))
            worst = max(worst, elapsed)
        }
        report("switch view mode, \(count) items (worst of 4)", worst, budget: count <= 10_000 ? 50 : 250)
    }

    @Test func resort100k() async throws {
        let dir = try Self.fixture(100_000)
        AppModel.shared = AppModel(store: AppSupportStore(directory: Self.fixtures.appendingPathComponent("store-\(UUID().uuidString)")))
        let state = BrowserState(location: .folder(dir))
        defer { state.invalidate() }
        await wait { state.loadState == .complete && state.snapshot.items.count == 100_000 }
        try await Task.sleep(for: .milliseconds(300))
        for key in [SortKey.size, .kind, .name, .dateModified] {
            let generation = state.snapshot.generation
            let t0 = DispatchTime.now().uptimeNanoseconds
            state.updateArrangement { $0.setPrimary(key) }
            await wait { state.snapshot.generation > generation }
            report("re-sort 100k by \(key.title)", ms(since: t0), budget: 300)
        }
    }
}
