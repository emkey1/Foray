import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations

@MainActor
@Suite struct AliasTests {
    @Test func makeAliasResolvesAndUndoes() async throws {
        let s = try Sandbox()
        let doc = s.file("docs/report.pdf", "R")
        let folder = s.dir("Projects")
        let r = await s.run(.makeAlias([doc, folder]))
        #expect(r.errors.isEmpty)
        #expect(r.created.map(\.lastPathComponent) == ["report.pdf alias", "Projects alias"])
        if case .target(let t) = Aliases.resolve(r.created[0]) { #expect(t.lastPathComponent == "report.pdf") } else { Issue.record("alias didn't resolve") }
        let again = await s.run(.makeAlias([doc]))
        #expect(again.created.first?.lastPathComponent == "report.pdf alias 2")
        // Aliases follow the original when it moves (they're bookmarks, not paths).
        try FileManager.default.moveItem(at: doc, to: s.work.appendingPathComponent("moved.pdf"))
        if case .target(let t) = Aliases.resolve(r.created[0]) { #expect(t.lastPathComponent == "moved.pdf") } else { Issue.record("alias broke on move") }
        await s.undo()
        #expect(!s.exists("docs/report.pdf alias 2"))
    }

    @Test func brokenAliasesAndSymlinks() throws {
        let s = try Sandbox()
        let doc = s.file("a.txt")
        let alias = s.work.appendingPathComponent("a alias")
        try Aliases.make(to: doc, at: alias)
        let link = s.work.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: doc)
        if case .target = Aliases.resolve(link) {} else { Issue.record("symlink should resolve") }
        try FileManager.default.removeItem(at: doc)
        #expect(Aliases.resolve(alias) == .broken)
        #expect(Aliases.resolve(link) == .broken)
        #expect(Aliases.resolve(s.file("plain.txt")) == .notAnAlias)
    }
}

@MainActor
@Suite struct ArchiveTests {
    @Test func compressOneItemAndExpandItBack() async throws {
        let s = try Sandbox()
        s.file("Photos/a.jpg", "A")
        s.file("Photos/sub/b.jpg", "B")
        let photos = s.work.appendingPathComponent("Photos")
        let r = await s.run(.compress([photos]))
        #expect(r.errors.isEmpty)
        let zip = try #require(r.created.first)
        #expect(zip.lastPathComponent == "Photos.zip")
        let original = s.tree(photos)

        // Expanding beside the original keeps both: "Photos 2".
        let x = await s.run(.expand([zip]))
        #expect(x.errors.isEmpty)
        #expect(x.created.first?.lastPathComponent == "Photos 2")
        #expect(s.tree(s.work.appendingPathComponent("Photos 2")) == original)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: s.work.path)).contains { $0.contains(OperationJournal.marker) })

        await s.undo()   // the expanded folder goes to the Trash
        #expect(!s.exists("Photos 2"))
    }

    @Test func severalItemsMakeArchiveZip() async throws {
        let s = try Sandbox()
        let a = s.file("a.txt", "A"), b = s.file("b.txt", "B")
        let r = await s.run(.compress([a, b]))
        let zip = try #require(r.created.first)
        #expect(zip.lastPathComponent == "Archive.zip")
        #expect(await s.run(.compress([a, b])).created.first?.lastPathComponent == "Archive 2.zip")
        // Several top-level items expand into a folder named after the archive.
        let x = await s.run(.expand([zip]))
        let folder = try #require(x.created.first)
        #expect(folder.lastPathComponent == "Archive")
        #expect(s.tree(folder) == ["a.txt": "A", "b.txt": "B"])
    }

    @Test func notAnArchiveFailsCleanly() async throws {
        let s = try Sandbox()
        let fake = s.file("fake.zip", "not a zip")
        let r = await s.run(.expand([fake]))
        #expect(r.errors.count == 1 && r.created.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.work.path) == ["fake.zip"])
    }
}

@MainActor
@Suite struct BatchRenameEngineTests {
    @Test func cyclesWorkAndUndoInOneStep() async throws {
        let s = try Sandbox()
        let a = s.file("a.txt", "A"), b = s.file("b.txt", "B"), c = s.file("c.txt", "C")
        let dir = s.work
        // a → b, b → c, c → a: a rotation that needs temporary names.
        let r = await s.run(.batchRename([
            .init(from: a, to: dir.appendingPathComponent("b.txt")),
            .init(from: b, to: dir.appendingPathComponent("c.txt")),
            .init(from: c, to: dir.appendingPathComponent("a.txt")),
        ]))
        #expect(r.errors.isEmpty)
        #expect(s.tree() == ["b.txt": "A", "c.txt": "B", "a.txt": "C"])
        #expect(s.center.undoManager.undoActionName == "Rename")
        await s.undo()
        #expect(s.tree() == ["a.txt": "A", "b.txt": "B", "c.txt": "C"])
        await s.redo()
        #expect(s.tree() == ["b.txt": "A", "c.txt": "B", "a.txt": "C"])
    }

    @Test func aClashWithAnOutsideItemLeavesThatItemAlone() async throws {
        let s = try Sandbox()
        let a = s.file("a.txt", "A"), b = s.file("b.txt", "B")
        s.file("taken.txt", "T")
        let r = await s.run(.batchRename([
            .init(from: a, to: s.work.appendingPathComponent("taken.txt")),
            .init(from: b, to: s.work.appendingPathComponent("bee.txt")),
        ]))
        #expect(r.errors.count == 1)
        #expect(s.tree() == ["a.txt": "A", "bee.txt": "B", "taken.txt": "T"])
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: s.work.path)).contains { $0.hasPrefix(".rfrename") })
    }
}
