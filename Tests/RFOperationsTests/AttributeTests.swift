import Darwin
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations

@MainActor
@Suite(.serialized) struct AttributeTests {
    init() { Comments.tellFinder = false }   // never drive the real Finder from tests

    private func mode(_ url: URL) -> UInt16 {
        var st = stat()
        lstat(url.path, &st)
        return UInt16(st.st_mode & 0o777)
    }

    @Test func lockHideExtensionPermissionsAndCommentsUndo() async throws {
        let s = try Sandbox()
        let f = s.file("notes.txt", "n")
        chmod(f.path, 0o644)

        _ = await s.run(.setAttributes([.init(url: f, attributes: ItemAttributes(permissions: 0o600))]))
        #expect(mode(f) == 0o600)
        _ = await s.run(.setAttributes([.init(url: f, attributes: ItemAttributes(extensionHidden: true))]))
        #expect(ItemAttributes.read(f, fields: ItemAttributes(extensionHidden: true)).extensionHidden == true)
        _ = await s.run(.setAttributes([.init(url: f, attributes: ItemAttributes(comment: "Quarterly figures"))]))
        #expect(Comments.read(f) == "Quarterly figures")
        let lock = await s.run(.setAttributes([.init(url: f, attributes: ItemAttributes(locked: true))]))
        #expect(lock.errors.isEmpty)
        #expect(s.center.undoManager.undoActionName == "Locked")

        // A locked item refuses changes, but changing it together with unlocking works.
        let refused = await s.run(.rename(f, to: "other.txt"))
        #expect(!refused.errors.isEmpty)

        await s.undo()   // unlock
        #expect(ItemAttributes.read(f, fields: ItemAttributes(locked: true)).locked == false)
        await s.undo()   // comment
        #expect(Comments.read(f).isEmpty)
        await s.undo()   // extension shown again
        #expect(ItemAttributes.read(f, fields: ItemAttributes(extensionHidden: true)).extensionHidden == false)
        await s.undo()   // permissions
        #expect(mode(f) == 0o644)
        await s.redo()
        #expect(mode(f) == 0o600)
    }

    @Test func noChangeRecordsNothing() async throws {
        let s = try Sandbox()
        let f = s.file("a.txt")
        let r = await s.run(.setAttributes([.init(url: f, attributes: ItemAttributes(locked: false))]))
        #expect(r.log.isEmpty && r.errors.isEmpty)
    }

    @Test func commentsRoundTripAndClear() throws {
        let s = try Sandbox()
        let f = s.file("c.txt")
        #expect(Comments.write("héllo ✓", to: f).errno == 0)
        #expect(Comments.read(f) == "héllo ✓")
        #expect(Comments.write("", to: f).errno == 0)
        #expect(Comments.read(f) == "")
        #expect(Comments.write("", to: f).errno == 0)   // clearing twice is fine
    }
}
