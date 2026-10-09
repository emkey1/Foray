import Darwin
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations

@MainActor
@Suite(.serialized) struct AccessTests {
    init() { Comments.tellFinder = false }

    func mode(_ url: URL) -> UInt16 {
        var st = stat()
        lstat(url.path, &st)
        return UInt16(st.st_mode & 0o777)
    }

    @Test func accessListsRoundTripAndUndo() async throws {
        let s = try Sandbox()
        let f = s.file("shared.txt")
        #expect(AccessList.text(f).isEmpty)
        let staff = AccessEntry.make(.group, name: "staff", id: 20, level: .readWrite, isDirectory: false)
        #expect(!staff.uuid.isEmpty)
        let text = AccessList.text(for: [staff])
        let r = await s.run(.setAttributes([.init(url: f, attributes: ItemAttributes(accessList: text))]))
        #expect(r.errors.isEmpty)
        let entries = AccessList.entries(AccessList.text(f))
        #expect(entries.count == 1 && entries[0].name == "staff" && entries[0].level == .readWrite)

        // Change the level, then undo back to Read & Write, then to none.
        let readOnly = AccessList.text(for: [entries[0].with(level: .readOnly, isDirectory: false)])
        _ = await s.run(.setAttributes([.init(url: f, attributes: ItemAttributes(accessList: readOnly))]))
        #expect(AccessList.entries(AccessList.text(f)).first?.level == .readOnly)
        await s.undo()
        #expect(AccessList.entries(AccessList.text(f)).first?.level == .readWrite)
        await s.undo()
        #expect(AccessList.text(f).isEmpty)
    }

    @Test func parsesWhatMacOSWrites() {
        let text = """
        !#acl 1
        group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny:delete
        user:FFFFEEEE-DDDD-CCCC-BBBB-AAAA000001F5:mke:501:allow,file_inherit,directory_inherit,inherited:read,execute,readattr,readextattr,readsecurity

        """
        let e = AccessList.entries(text)
        #expect(e.count == 2)
        #expect(e[0].level == .custom && !e[0].allow)
        #expect(e[1].level == .readOnly && e[1].isInherited && e[1].tag == .user && e[1].id == 501)
        #expect(AccessList.entries(AccessList.text(for: e)) == e)   // writes back the same
    }

    @Test func stationeryFlagSurvivesOtherFinderInfo() async throws {
        let s = try Sandbox()
        let f = s.file("letterhead.txt")
        #expect(!Stationery.isSet(f))
        _ = await s.run(.setAttributes([.init(url: f, attributes: ItemAttributes(stationery: true))]))
        #expect(Stationery.isSet(f))
        #expect(DirectoryLoader.shared.stat(f)?.flags.contains(.stationery) == true)
        await s.undo()
        #expect(!Stationery.isSet(f))
    }

    @Test func applyToEnclosedItems() async throws {
        let s = try Sandbox()
        let folder = s.dir("Project")
        let script = s.file("Project/run.sh"), doc = s.file("Project/sub/notes.txt")
        chmod(script.path, 0o700)
        chmod(doc.path, 0o600)
        chmod(folder.path, 0o755)
        let staff = AccessEntry.make(.group, name: "staff", id: 20, level: .readOnly, isDirectory: true)
        #expect(AccessList.write(AccessList.text(for: [staff]), to: folder) == 0)

        let r = await s.run(.applyAccessToEnclosed(folder))
        #expect(r.errors.isEmpty)
        #expect(mode(script) == 0o744)   // keeps its own execute bit, gains read for group/everyone
        #expect(mode(doc) == 0o644)
        #expect(mode(s.work.appendingPathComponent("Project/sub")) == 0o755)
        let fileACL = AccessList.entries(AccessList.text(doc))
        #expect(fileACL.first?.level == .readOnly && fileACL.first?.flags.isEmpty == true)   // no inherit flags on files
        #expect(AccessList.entries(AccessList.text(s.work.appendingPathComponent("Project/sub"))).first?.flags.contains("file_inherit") == true)

        await s.undo()
        #expect(mode(script) == 0o700 && mode(doc) == 0o600)
        #expect(AccessList.text(doc).isEmpty)
    }
}
