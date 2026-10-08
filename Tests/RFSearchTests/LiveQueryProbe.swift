import Foundation
import Testing
@testable import RFModel
@testable import RFSearch
@testable import RFFileSystem

/// Manual probe: RF_PROBE_DIR=<folder> RF_PROBE_QUERY=<query> swift test --filter LiveQueryProbe
@Suite(.disabled(if: ProcessInfo.processInfo.environment["RF_PROBE_DIR"] == nil)) struct LiveQueryProbe {
    @Test func run() async {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: (env["RF_PROBE_DIR"]! as NSString).expandingTildeInPath)
        let q = SearchQuery(text: env["RF_PROBE_QUERY"] ?? "", scope: .folder(dir, recursive: true))
        let t0 = Date()
        var last = SearchStatus()
        for await s in SearchEngine.run(q) { last = s; if !s.isRunning { break } }
        print("PROBE \(last.items.count) results in \(Int(Date().timeIntervalSince(t0) * 1000)) ms; folders \(last.foldersScanned), skipped \(last.foldersSkipped); problems \(QueryParser.problems(in: q.text))")
    }
}

@Suite(.disabled(if: ProcessInfo.processInfo.environment["RF_WALK_DIR"] == nil)) struct WalkProbe {
    @Test func walk() async {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: (env["RF_WALK_DIR"]! as NSString).expandingTildeInPath)
        for concurrency in [4, 8, 16, 32] {
            let t0 = Date()
            var folders = 0
            for await e in TreeWalker.walk(dir, options: .init(concurrency: concurrency), nameFilter: { _ in false }) {
                if case .progress(let p) = e { folders = p.foldersScanned }
            }
            print("WALK c=\(concurrency): \(folders) folders in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
    }
}
