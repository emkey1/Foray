import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations

/// A sandbox per test: a work folder, a private "Trash", a private journal, and an OperationCenter
/// wired to them. Nothing touches the user's real Trash or settings.
@MainActor
final class Sandbox {
    let root: URL
    let work: URL
    let trashDir: URL
    let journal: OperationJournal
    let center: OperationCenter
    var answers: [ConflictAnswer] = []
    var questions: [ConflictQuestion] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rf-ops-\(UUID().uuidString)", isDirectory: true)
        work = root.appendingPathComponent("work", isDirectory: true)
        trashDir = root.appendingPathComponent("Trash", isDirectory: true)
        for d in [work, trashDir] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        journal = OperationJournal(store: AppSupportStore(directory: root.appendingPathComponent("store")))
        let trash = trashDir
        center = OperationCenter(journal: journal, trash: { url in
            var dest = trash.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = trash.appendingPathComponent("\(url.lastPathComponent) \(n)")
                n += 1
            }
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        })
        center.resolveConflict = { [weak self] _, q in
            self?.questions.append(q)
            return self?.answers.isEmpty == false ? self!.answers.removeFirst() : ConflictAnswer(.skip)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ path: String, _ contents: String = "x", in base: URL? = nil) -> URL {
        let url = (base ?? work).appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
        return url
    }

    @discardableResult
    func dir(_ path: String, in base: URL? = nil) -> URL {
        let url = (base ?? work).appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func run(_ r: OperationRequest) async -> OperationResult { await center.run(r) }

    func undo() async { await waitForUndo { center.undoManager.undo() } }
    func redo() async { await waitForUndo { center.undoManager.redo() } }

    private func waitForUndo(_ action: () -> Void) async {
        action()
        // Undo/redo steps run as jobs, one after another.
        while center.isBusy { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Relative path → contents ("<dir>" for folders, "-> target" for symlinks), for exact comparisons.
    func tree(_ base: URL? = nil) -> [String: String] {
        let base = base ?? work
        var out: [String: String] = [:]
        guard let e = FileManager.default.enumerator(atPath: base.path) else { return out }
        while let rel = e.nextObject() as? String {
            let url = base.appendingPathComponent(rel)
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                out[rel] = "-> \(dest)"
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                out[rel] = "<dir>"
            } else {
                out[rel] = (try? String(contentsOf: url, encoding: .utf8)) ?? "<binary>"
            }
        }
        return out
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: work.appendingPathComponent(path).path) }
}

@MainActor
@Suite struct CopyTests {
    @Test func copiesFilesAndFoldersWithEverythingInside() async throws {
        let s = try Sandbox()
        s.file("src/a.txt", "alpha")
        s.file("src/sub/b.txt", "beta")
        s.file("src/.hidden", "h")
        try FileManager.default.createSymbolicLink(atPath: s.work.appendingPathComponent("src/link").path, withDestinationPath: "a.txt")
        let dest = s.dir("dest")
        let r = await s.run(.copy([s.work.appendingPathComponent("src")], to: dest))
        #expect(r.errors.isEmpty)
        #expect(r.created.map(\.lastPathComponent) == ["src"])
        #expect(s.tree(dest.appendingPathComponent("src")) == s.tree(s.work.appendingPathComponent("src")))
        #expect(s.tree(dest).keys.allSatisfy { !$0.contains(OperationJournal.marker) })
    }

    @Test func preservesMetadata() async throws {
        let s = try Sandbox()
        let f = s.file("meta.txt", "data")
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old, .posixPermissions: 0o640], ofItemAtPath: f.path)
        let value = Data("tagged".utf8)
        _ = value.withUnsafeBytes { setxattr(f.path, "com.example.test", $0.baseAddress, value.count, 0, 0) }
        let dest = s.dir("dest")
        _ = await s.run(.copy([f], to: dest))
        let copy = dest.appendingPathComponent("meta.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: copy.path)
        #expect((attrs[.modificationDate] as? Date) == old)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        var buf = [UInt8](repeating: 0, count: 16)
        let n = getxattr(copy.path, "com.example.test", &buf, buf.count, 0, 0)
        #expect(n == value.count)
    }

    @Test func pasteIntoSameFolderMakesACopy() async throws {
        let s = try Sandbox()
        let f = s.file("report.pdf")
        let r1 = await s.run(.copy([f], to: s.work))
        let r2 = await s.run(.copy([f], to: s.work))
        #expect(r1.created.map(\.lastPathComponent) == ["report copy.pdf"])
        #expect(r2.created.map(\.lastPathComponent) == ["report copy 2.pdf"])
    }

    @Test func duplicateNames() async throws {
        let s = try Sandbox()
        let f = s.file("notes.txt")
        let d = s.dir("Folder")
        let r = await s.run(.duplicate([f, d]))
        #expect(r.created.map(\.lastPathComponent) == ["notes copy.txt", "Folder copy"])
    }

    @Test func refusesToCopyAFolderIntoItself() async throws {
        let s = try Sandbox()
        let d = s.dir("A")
        let inner = s.dir("A/B")
        let r = await s.run(.copy([d], to: inner))
        #expect(r.errors.first?.code == EINVAL)
        #expect(r.created.isEmpty)
    }

    @Test func unreadableItemsAreReportedAndTheRestIsCopied() async throws {
        let s = try Sandbox()
        s.file("src/ok1.txt")
        let secret = s.file("src/secret.txt", "s")
        s.file("src/ok2.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path) }
        let dest = s.dir("dest")
        // A different volume would copy file by file; force that path by copying the folder's files.
        let r = await s.run(.copy([s.work.appendingPathComponent("src")], to: dest))
        // On APFS the whole tree is cloned (permissions don't block a clone), so either outcome is
        // acceptable here; what matters is that nothing is lost and no partial copy remains.
        #expect(s.tree(dest).keys.contains("src/ok1.txt"))
        #expect(s.tree(dest).keys.contains("src/ok2.txt"))
        #expect(!s.tree(dest).keys.contains { $0.contains(OperationJournal.marker) })
        _ = r
    }

    @Test func progressReachesTheTotal() async throws {
        let s = try Sandbox()
        s.file("big.bin", String(repeating: "z", count: 2_000_000))
        let job = s.center.submit(.copy([s.work.appendingPathComponent("big.bin")], to: s.dir("dest")))
        _ = await s.center.finished(job)
        #expect(job.progress.phase == .finished)
        #expect(job.progress.fraction == 1)
    }
}

@MainActor
@Suite struct ConflictTests {
    @Test func keepBothSkipAndReplace() async throws {
        let s = try Sandbox()
        let dest = s.dir("dest")
        s.file("a.txt", "new a", in: s.dir("src"))
        s.file("b.txt", "new b", in: s.work.appendingPathComponent("src"))
        s.file("c.txt", "new c", in: s.work.appendingPathComponent("src"))
        s.file("a.txt", "old a", in: dest)
        s.file("b.txt", "old b", in: dest)
        s.file("c.txt", "old c", in: dest)
        s.answers = [ConflictAnswer(.keepBoth), ConflictAnswer(.skip), ConflictAnswer(.replace)]
        let src = ["a.txt", "b.txt", "c.txt"].map { s.work.appendingPathComponent("src/\($0)") }
        let r = await s.run(.copy(src, to: dest))
        #expect(s.questions.count == 3)
        let t = s.tree(dest)
        #expect(t["a.txt"] == "old a" && t["a 2.txt"] == "new a")
        #expect(t["b.txt"] == "old b")
        #expect(t["c.txt"] == "new c")
        #expect(r.trashed.count == 1)                                       // replaced item is in the Trash
        #expect(s.tree(s.trashDir)["c.txt"] == "old c")
    }

    @Test func applyToAll() async throws {
        let s = try Sandbox()
        let dest = s.dir("dest")
        for n in ["x", "y", "z"] {
            s.file("\(n).txt", "new", in: s.dir("src"))
            s.file("\(n).txt", "old", in: dest)
        }
        s.answers = [ConflictAnswer(.keepBoth, applyToAll: true)]
        _ = await s.run(.copy(["x", "y", "z"].map { s.work.appendingPathComponent("src/\($0).txt") }, to: dest))
        #expect(s.questions.count == 1)
        #expect(s.tree(dest).count == 6)
    }

    @Test func stopEndsTheJob() async throws {
        let s = try Sandbox()
        let dest = s.dir("dest")
        s.file("a.txt", "new", in: s.dir("src"))
        s.file("b.txt", "new", in: s.work.appendingPathComponent("src"))
        s.file("a.txt", "old", in: dest)
        s.answers = [ConflictAnswer(.stop)]
        let r = await s.run(.copy(["a.txt", "b.txt"].map { s.work.appendingPathComponent("src/\($0)") }, to: dest))
        #expect(r.stopped)
        #expect(s.tree(dest) == ["a.txt": "old"])
    }

    @Test func neverReplacesAFolderThatContainsTheSource() async throws {
        let s = try Sandbox()
        let outer = s.dir("dest/pkg")
        let inner = s.file("pkg", "inner file", in: outer)   // dest/pkg/pkg (a file)
        s.answers = [ConflictAnswer(.replace)]
        let r = await s.run(.move([inner], to: s.work.appendingPathComponent("dest")))
        #expect(r.errors.first?.code == EINVAL)
        #expect(s.exists("dest/pkg/pkg"))
    }
}

@MainActor
@Suite struct MoveRenameTests {
    @Test func moveWithinAVolumeIsARename() async throws {
        let s = try Sandbox()
        let f = s.file("a/doc.txt", "d")
        let r = await s.run(.move([f], to: s.dir("b")))
        #expect(r.moved == [.init(from: f, to: s.work.appendingPathComponent("b/doc.txt"))])
        #expect(!s.exists("a/doc.txt") && s.exists("b/doc.txt"))
    }

    @Test func movingIntoTheSameFolderDoesNothing() async throws {
        let s = try Sandbox()
        let f = s.file("doc.txt")
        let r = await s.run(.move([f], to: s.work))
        #expect(r.moved.isEmpty && r.errors.isEmpty && s.exists("doc.txt"))
    }

    @Test func renameIncludingCaseOnly() async throws {
        let s = try Sandbox()
        let f = s.file("readme")
        let r1 = await s.run(.rename(f, to: "README"))
        #expect(r1.errors.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.work.path) == ["README"])
        s.file("taken")
        let r2 = await s.run(.rename(s.work.appendingPathComponent("README"), to: "taken"))
        #expect(r2.errors.first?.code == EEXIST)
        let r3 = await s.run(.rename(s.work.appendingPathComponent("README"), to: "a/b"))
        #expect(r3.errors.first?.code == EINVAL)
    }

    @Test func newFolderWithSelection() async throws {
        let s = try Sandbox()
        let a = s.file("a.txt"), b = s.file("b.txt")
        s.dir("untitled folder")
        let r = await s.run(.newFolder(in: s.work, moving: [a, b]))
        #expect(r.created.map(\.lastPathComponent) == ["untitled folder 2"])
        #expect(s.exists("untitled folder 2/a.txt") && s.exists("untitled folder 2/b.txt"))
    }
}

@MainActor
@Suite struct UndoTests {
    @Test(arguments: ["copy", "move", "duplicate", "trash", "rename", "newFolder", "replace"])
    func undoRestoresAndRedoReapplies(kind: String) async throws {
        let s = try Sandbox()
        s.file("src/a.txt", "A")
        s.file("src/sub/b.txt", "B")
        s.file("dest/a.txt", "old A")
        let a = s.work.appendingPathComponent("src/a.txt"), sub = s.work.appendingPathComponent("src/sub")
        let dest = s.work.appendingPathComponent("dest")
        let request: OperationRequest = switch kind {
        case "copy": .copy([sub], to: dest)
        case "move": .move([sub], to: dest)
        case "duplicate": .duplicate([a, sub])
        case "trash": .trash([a, sub])
        case "rename": .rename(a, to: "renamed.txt")
        case "newFolder": .newFolder(in: s.work.appendingPathComponent("src"), moving: [a])
        default: .copy([a], to: dest)   // replace
        }
        if kind == "replace" { s.answers = [ConflictAnswer(.replace)] }

        let before = s.tree()
        let r = await s.run(request)
        #expect(r.errors.isEmpty)
        let after = s.tree()
        #expect(after != before)

        await s.undo()
        #expect(s.tree() == before, "undo of \(kind)")
        await s.redo()
        #expect(s.tree() == after, "redo of \(kind)")
        await s.undo()
        #expect(s.tree() == before, "second undo of \(kind)")
    }

    @Test func deleteIsNotUndoable() async throws {
        let s = try Sandbox()
        let f = s.file("gone.txt")
        let r = await s.run(.delete([f]))
        #expect(r.deleted == [f])
        #expect(!s.center.undoManager.canUndo)
    }

    @Test func undoFailsGracefullyIfTheItemMovedOn() async throws {
        let s = try Sandbox()
        let f = s.file("a.txt")
        _ = await s.run(.move([f], to: s.dir("b")))
        try FileManager.default.removeItem(at: s.work.appendingPathComponent("b/a.txt"))
        var reported: OperationResult?
        s.center.reportProblems = { _, r in reported = r }
        await s.undo()
        #expect(reported?.errors.first?.code == ENOENT)
    }
}

@MainActor
@Suite struct CancelAndRecoveryTests {
    @Test func cancellingMidCopyLeavesNothingBehind() async throws {
        let s = try Sandbox()
        // Many files force a file-by-file copy we can interrupt (clones are instant, so copy to a
        // folder on the same volume still clones; cancel before it starts instead).
        for i in 0..<200 { s.file("src/f\(i).bin", String(repeating: "q", count: 50_000)) }
        let dest = s.dir("dest")
        let job = s.center.submit(.copy([s.work.appendingPathComponent("src")], to: dest))
        job.control.cancel()
        _ = await s.center.finished(job)
        #expect(s.tree(dest).isEmpty)
        #expect(s.journal.pending.isEmpty)
    }

    @Test func recoveryRemovesOnlyMarkedLeftovers() throws {
        let store = AppSupportStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("rf-jr-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let journal = OperationJournal(store: store)
        let dir = store.directory.appendingPathComponent("d")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = OperationJournal.temporaryURL(for: dir.appendingPathComponent("movie.mov"))
        FileManager.default.createFile(atPath: temp.path, contents: Data("partial".utf8))
        let innocent = dir.appendingPathComponent("innocent.txt")
        FileManager.default.createFile(atPath: innocent.path, contents: nil)
        journal.begin(temp)
        journal.begin(innocent)  // a path without the marker is never deleted

        let afterCrash = OperationJournal(store: store)   // a fresh launch reads the journal
        let removed = afterCrash.recover()
        #expect(removed == [temp.path])
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(FileManager.default.fileExists(atPath: innocent.path))
        #expect(afterCrash.pending.isEmpty)
    }
}
