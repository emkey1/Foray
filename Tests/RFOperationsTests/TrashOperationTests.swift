import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations

@MainActor
@Suite struct PutBackAndEmptyTrashTests {
    @Test func putBackReturnsItemsTrashedTogether() async throws {
        let s = try Sandbox()
        let a = s.file("one/a.txt", "A"), b = s.file("two/deep/b.txt", "B"), c = s.file("c.txt", "C")
        let r = await s.run(.trash([a, b, c]))
        #expect(r.trashed.count == 3)
        let trashed = r.trashed.map(\.to)
        // Foray's own records cover every item, even ones trashed in the same instant.
        let d = s.center.putBackDestinations(for: trashed)
        #expect(Set(d.values.map(\.path)) == Set([a, b, c].map(\.path)))

        // The parent folder is recreated if it's gone, like Finder.
        try FileManager.default.removeItem(at: s.work.appendingPathComponent("two"))
        let back = await s.run(.putBack(trashed.map { OperationRequest.Pair(from: $0, to: d[$0]!) }))
        #expect(back.errors.isEmpty)
        #expect(s.tree()["two/deep/b.txt"] == "B" && s.tree()["one/a.txt"] == "A" && s.tree()["c.txt"] == "C")
        #expect(s.center.undoManager.undoActionName == "Put Back")

        await s.undo()
        #expect(!s.exists("one/a.txt") && !s.exists("c.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.trashDir.path).count == 3)
    }

    @Test func recordsOnlyMatchTheSameItem() async throws {
        let s = try Sandbox()
        let a = s.file("a.txt")
        let r = await s.run(.trash([a]))
        let inTrash = try #require(r.trashed.first?.to)
        #expect(s.center.putBackDestinations(for: [inTrash])[inTrash] == a)
        // A different item later at the same path in the Trash isn't mistaken for it.
        try FileManager.default.removeItem(at: inTrash)
        FileManager.default.createFile(atPath: inTrash.path, contents: Data("other".utf8))
        #expect(s.center.putBackDestinations(for: [inTrash])[inTrash] == nil)
    }

    @Test func putBackRefusesToOverwrite() async throws {
        let s = try Sandbox()
        let a = s.file("a.txt", "old")
        let r = await s.run(.trash([a]))
        s.file("a.txt", "new")
        let back = await s.run(.putBack([.init(from: r.trashed[0].to, to: a)]))
        #expect(back.errors.first?.code == EEXIST)
        #expect(s.tree()["a.txt"] == "new")
    }

    @Test func emptyTrashErasesEverythingInEachTrashAndCantBeUndone() async throws {
        let s = try Sandbox()
        let second = s.dir("OtherVolumeTrash")
        s.file("x.txt", in: s.trashDir)
        s.file("folder/y.txt", in: s.trashDir)
        s.file(".DS_Store", in: s.trashDir)
        s.file("z.txt", in: second)
        let keep = s.file("keep.txt")
        let r = await s.run(.emptyTrash([s.trashDir, second]))
        #expect(r.errors.isEmpty)
        #expect(r.deleted.count == 4)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.trashDir.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: second.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(!s.center.undoManager.canUndo)
    }

    @Test func unreadableTrashIsReportedNotSkipped() async throws {
        let s = try Sandbox()
        let r = await s.run(.emptyTrash([s.root.appendingPathComponent("no-such-trash")]))
        #expect(r.errors.first?.code == ENOENT)
    }

    @Test func journalSurvivesRelaunch() async throws {
        let s = try Sandbox()
        let a = s.file("a.txt")
        let r = await s.run(.trash([a]))
        let reopened = OperationJournal(store: AppSupportStore(directory: s.root.appendingPathComponent("store")))
        #expect(reopened.putBackLocation(for: r.trashed[0].to) == a)
    }
}

struct SystemTrashSafetyTests {
    @Test func theDefaultTrashIsPrivateInTests() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("rf-safety-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: f.path, contents: nil)
        let dest = try Trash.system(f)
        defer { try? FileManager.default.removeItem(at: dest) }
        #expect(!dest.path.contains("/.Trash"))
        #expect(dest.path.contains("rf-test-trash-"))
    }
}
