import Foundation
import Testing

@testable import RFFileSystem
@testable import RFOperations

/// M2 exit criterion: no data loss if the app is killed (kill -9) mid-copy. A partial copy must
/// never appear under the real name, the source must be untouched, and the next launch's
/// recovery must remove the leftover.
@Suite struct CrashTests {
    /// The probe is built alongside the tests (it's a dependency of this test target).
    static var probe: URL? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [".build/out/Products/Debug", ".build/out/Products/Release", ".build/debug", ".build/release"]
            .map { root.appendingPathComponent($0).appendingPathComponent("rf-crash-probe") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @Test func killMidCopyLosesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rf-crash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src"), dest = root.appendingPathComponent("dest"), store = root.appendingPathComponent("store")
        for d in [src, dest, store] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let big = src.appendingPathComponent("big.bin")
        var bytes = [UInt8](repeating: 0, count: 64 * 1024 * 1024)
        for i in stride(from: 0, to: bytes.count, by: 4096) { bytes[i] = UInt8(truncatingIfNeeded: i / 4096) }
        try Data(bytes).write(to: big)

        let p = Process()
        p.executableURL = try #require(Self.probe, "rf-crash-probe not built")
        p.arguments = [big.path, dest.path, store.path]
        p.environment = ProcessInfo.processInfo.environment.merging(["RF_TEST_NO_CLONE": "1", "RF_TEST_SLOW_COPY": "1"]) { $1 }
        p.standardOutput = FileHandle.nullDevice
        try p.run()

        // Wait until the copy is under way (a partial temporary file with some data).
        func partial() -> URL? {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []
            guard let name = names.first(where: { $0.contains(OperationJournal.marker) }) else { return nil }
            let url = dest.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            return size > 0 ? url : nil
        }
        let deadline = Date().addingTimeInterval(20)
        while partial() == nil && p.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let temp = try #require(partial(), "the copy never started")
        kill(p.processIdentifier, SIGKILL)
        p.waitUntilExit()

        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("big.bin").path), "partial copy under the real name")
        #expect(try Data(contentsOf: big) == Data(bytes), "source changed")
        let journal = OperationJournal(store: AppSupportStore(directory: store))   // "next launch"
        #expect(journal.pending == [temp.path])
        #expect(journal.recover() == [temp.path])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }
}
