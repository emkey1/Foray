import Foundation
import Testing

@testable import RFModel
@testable import RFOperations

/// A disk image formatted with a given filesystem, mounted (hidden from Finder) for one test.
final class TestVolume {
    let mountPoint: URL
    private let image: URL

    init(_ fs: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rf-vol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        image = dir.appendingPathComponent("vol.dmg")
        mountPoint = dir.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try Self.hdiutil(["create", "-size", "128m", "-fs", fs, "-volname", "RFTest", "-ov", image.path])
        try Self.hdiutil(["attach", "-nobrowse", "-noverify", "-mountpoint", mountPoint.path, image.path])
    }

    deinit {
        try? Self.hdiutil(["detach", "-force", mountPoint.path])
        try? FileManager.default.removeItem(at: image.deletingLastPathComponent())
    }

    static func hdiutil(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "hdiutil", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")]) }
    }
}

/// DESIGN.md §8: every operation on every filesystem. Opt-in (mounts disk images):
///   RF_FS_MATRIX=1 swift test --filter FileSystemMatrixTests
@MainActor
@Suite(.serialized, .disabled(if: ProcessInfo.processInfo.environment["RF_FS_MATRIX"] == nil))
struct FileSystemMatrixTests {
    nonisolated static let formats = ["APFS", "Case-sensitive APFS", "HFS+", "ExFAT", "MS-DOS FAT32"]

    private func populate(_ s: Sandbox, under dir: String) throws {
        s.file("\(dir)/a.txt", "alpha")
        s.file("\(dir)/sub/b.txt", String(repeating: "b", count: 300_000))
        s.file("\(dir)/.hidden", "h")
        try FileManager.default.createSymbolicLink(atPath: s.work.appendingPathComponent("\(dir)/link").path, withDestinationPath: "a.txt")
    }

    /// FAT and exFAT keep xattrs in "._" companion files; compare what each can hold.
    private func comparable(_ tree: [String: String], fs: String) -> [String: String] {
        tree.filter { key, _ in !(key as NSString).lastPathComponent.hasPrefix("._") }
    }

    @Test(arguments: formats)
    func copyMoveUndoAcrossVolumes(fs: String) async throws {
        let volume = try TestVolume(fs)
        let local = try Sandbox()
        try populate(local, under: "src")
        let remote = volume.mountPoint.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)

        // Copy to the other volume.
        let r1 = await local.run(.copy([local.work.appendingPathComponent("src")], to: remote))
        let symlinkErrors = r1.errors.filter { $0.url.lastPathComponent == "link" }
        #expect(r1.errors.count == symlinkErrors.count, "\(fs): \(r1.errors.map(\.message))")
        #expect(comparable(local.tree(remote.appendingPathComponent("src")), fs: fs)
                == comparable(local.tree(local.work.appendingPathComponent("src")), fs: fs), "\(fs) copy")

        // Move to the other volume (copy + delete original), then undo.
        let before = local.tree()
        try? FileManager.default.removeItem(at: remote.appendingPathComponent("src"))
        let r2 = await local.run(.move([local.work.appendingPathComponent("src")], to: remote))
        #expect(r2.errors.isEmpty, "\(fs): \(r2.errors.map(\.message))")
        #expect(!FileManager.default.fileExists(atPath: local.work.appendingPathComponent("src").path))
        await local.undo()
        #expect(comparable(local.tree(), fs: fs) == comparable(before, fs: fs), "\(fs) undo cross-volume move")
        #expect(!local.tree(remote).keys.contains { $0.contains(OperationJournal.marker) })
    }

    @Test(arguments: formats)
    func caseOnlyRenameAndFuzzOnTheVolume(fs: String) async throws {
        let volume = try TestVolume(fs)
        let s = try Sandbox(base: volume.mountPoint)
        let f = s.file("readme.txt", "r")
        let r = await s.run(.rename(f, to: "README.txt"))
        #expect(r.errors.isEmpty, "\(fs): \(r.errors.map(\.message))")
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.work.path).filter { !$0.hasPrefix("._") } == ["README.txt"])

        // A short random run on this filesystem, undone completely (starting from a clean undo stack).
        s.center.undoManager.removeAllActions()
        var rng = SeededRNG(state: 42)
        for path in ["a/1.txt", "a/2.txt", "b/3.txt", "c/d/4.txt"] { s.file(path, path) }
        let initial = comparable(s.tree(), fs: fs)
        var log: [String] = []
        for step in 0..<15 {
            let all = s.tree().filter { !($0.key as NSString).lastPathComponent.hasPrefix("._") }.keys.sorted().map { s.work.appendingPathComponent($0) }
            guard let pick = all.randomElement(using: &rng) else { break }
            let dirs = [s.work] + s.tree().filter { $0.value == "<dir>" }.keys.map { s.work.appendingPathComponent($0) }
            s.answers = [ConflictAnswer(.keepBoth)]
            let req: OperationRequest = switch step % 5 {
            case 0: .copy([pick], to: dirs.randomElement(using: &rng)!)
            case 1: .move([pick], to: dirs.randomElement(using: &rng)!)
            case 2: .duplicate([pick])
            case 3: .rename(pick, to: "r\(step)")
            default: .trash([pick])
            }
            let r = await s.run(req)
            log.append("\(step) \(req.title) errors=\(r.errors.map(\.message)) log=\(r.log.count)")
        }
        while s.center.undoManager.canUndo { await s.undo() }
        let end = comparable(s.tree(), fs: fs)
        let diff = Set(end.map { "\($0.key)=\($0.value)" }).symmetricDifference(initial.map { "\($0.key)=\($0.value)" })
        #expect(end == initial, "\(fs) fuzz undo; diff: \(diff.sorted())\n\(log.joined(separator: "\n"))")
    }
}
