import Foundation
import Testing
@testable import RFFileSystem

@Suite(.disabled(if: ProcessInfo.processInfo.environment["RF_PROBE"] == nil)) struct LatencyProbe {
    final class Stamp: @unchecked Sendable { var at: Date? }
    @Test func measure() async throws {
        for base in [FileManager.default.temporaryDirectory, URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")] {
            let dir = base.appendingPathComponent("rf-latency-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try await Task.sleep(for: .seconds(1))
            let watcher = DirectoryWatcher()
            let stamp = Stamp()
            let token = watcher.subscribe(dir) { if stamp.at == nil { stamp.at = Date() } }
            var samples: [Int] = []
            for i in 0..<5 {
                try await Task.sleep(for: .milliseconds(700))
                stamp.at = nil
                let t0 = Date()
                FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(i)").path, contents: Data())
                while stamp.at == nil && Date().timeIntervalSince(t0) < 5 { try await Task.sleep(for: .milliseconds(5)) }
                samples.append(stamp.at.map { Int($0.timeIntervalSince(t0) * 1000) } ?? -1)
            }
            watcher.unsubscribe(token)
            print("LATENCY \(base.path): \(samples) ms")
        }
    }
}
