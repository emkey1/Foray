import Foundation
import Synchronization
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations

/// Stands in for the privileged helper. Read-only folders play the part of protected ones: this
/// "administrator" can write in them (it opens them up for the moment of each operation), and it
/// runs the helper's real executor. Nothing here runs as root.
final class FakeAdministrator: PrivilegedFileOps, @unchecked Sendable {
    private let log = Mutex<[PrivilegedOperation]>([])
    var operations: [PrivilegedOperation] { log.withLock { $0 } }
    /// Answers every operation with this instead of doing it (a helper that says no).
    var refuseWith: Int32?

    func perform(_ operation: PrivilegedOperation) -> Int32 {
        log.withLock { $0.append(operation) }
        if let refuseWith { return refuseWith }
        var restore: [(String, mode_t)] = []
        for path in operation.paths {
            let parent = (path as NSString).deletingLastPathComponent
            var st = stat()
            if stat(parent, &st) == 0, st.st_mode & 0o200 == 0 {
                restore.append((parent, st.st_mode & 0o7777))
                chmod(parent, 0o755)
            }
        }
        defer { for (path, mode) in restore { chmod(path, mode) } }
        return PrivilegedExecutor.perform(operation, owner: getuid())
    }
}

/// Counts how often the user would have been asked to authenticate.
final class Prompt: @unchecked Sendable {
    let administrator: FakeAdministrator?
    private let count = Mutex(0)
    private let titles = Mutex<[String]>([])
    var asked: Int { count.withLock { $0 } }
    var lastTitle: String? { titles.withLock { $0.last } }

    init(_ administrator: FakeAdministrator?) { self.administrator = administrator }

    var provider: ElevationProvider {
        { [self] title in
            count.withLock { $0 += 1 }
            titles.withLock { $0.append(title) }
            return administrator
        }
    }
}

extension Sandbox {
    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    func names(in folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
}

@MainActor
@Suite struct PrivilegedTests {
    let box: Sandbox
    let protected: URL

    init() throws {
        box = try Sandbox()
        protected = box.dir("Protected")
    }

    private func lock(_ url: URL) { chmod(url.path, 0o555) }
    private func unlock(_ url: URL) { chmod(url.path, 0o755) }

    // MARK: The engine asks for an administrator only when it must

    @Test func copyIntoAProtectedFolderGoesThroughTheHelper() async {
        let source = box.file("report.txt", "figures")
        lock(protected)
        defer { unlock(protected) }
        let admin = FakeAdministrator(), prompt = Prompt(admin)
        box.center.elevation = prompt.provider
        let result = await box.center.run(.copy([source], to: protected))
        #expect(result.errors.isEmpty)
        #expect(box.read(protected.appendingPathComponent("report.txt")) == "figures")
        #expect(prompt.asked == 1)
        #expect(prompt.lastTitle?.contains("report.txt") == true)   // the dialog says what it's for
        // Only the steps that needed it went through the helper, and nothing was left behind.
        #expect(admin.operations.allSatisfy { $0.paths.contains { $0.hasPrefix(protected.path + "/") } })
        #expect(box.names(in: protected) == ["report.txt"])
        #expect(result.created == [protected.appendingPathComponent("report.txt")])
    }

    @Test func aFolderIsCopiedWithOneQuestion() async {
        box.file("Project/a.txt", "a")
        box.file("Project/Sub/b.txt", "b")
        lock(protected)
        defer { unlock(protected) }
        let admin = FakeAdministrator(), prompt = Prompt(admin)
        box.center.elevation = prompt.provider
        let result = await box.center.run(.copy([box.work.appendingPathComponent("Project")], to: protected))
        #expect(result.errors.isEmpty && prompt.asked == 1)
        #expect(box.read(protected.appendingPathComponent("Project/Sub/b.txt")) == "b")
        // The new folder belongs to the user, so its contents didn't need the helper at all.
        #expect(!admin.operations.contains { if case .copyFile = $0 { true } else { false } })
    }

    @Test func moveRenameNewFolderAndDeleteInAProtectedFolder() async {
        let incoming = box.file("incoming.txt", "in")
        box.file("old.txt", "old", in: protected)
        box.file("junk.txt", "junk", in: protected)
        lock(protected)
        defer { unlock(protected) }
        let prompt = Prompt(FakeAdministrator())
        box.center.elevation = prompt.provider

        #expect(await box.center.run(.move([incoming], to: protected)).errors.isEmpty)
        #expect(await box.center.run(.rename(protected.appendingPathComponent("old.txt"), to: "new.txt")).errors.isEmpty)
        #expect(await box.center.run(.newFolder(in: protected, name: "Made")).errors.isEmpty)
        #expect(await box.center.run(.delete([protected.appendingPathComponent("junk.txt")])).errors.isEmpty)
        #expect(box.names(in: protected) == ["Made", "incoming.txt", "new.txt"])
        #expect(!FileManager.default.fileExists(atPath: incoming.path))
        #expect(prompt.asked == 4)                                  // once per job, like Finder
    }

    @Test func undoGoesThroughTheHelperToo() async {
        let source = box.file("report.txt")
        lock(protected)
        defer { unlock(protected) }
        let prompt = Prompt(FakeAdministrator())
        box.center.elevation = prompt.provider
        let result = await box.center.run(.move([source], to: protected))
        #expect(result.errors.isEmpty)
        for step in result.revert() ?? [] { #expect(await box.center.run(step).errors.isEmpty) }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(box.names(in: protected).isEmpty)
    }

    @Test func withoutAdministratorAccessItFailsAsBefore() async {
        let source = box.file("report.txt")
        lock(protected)
        defer { unlock(protected) }
        // Off (the default): nothing is asked.
        #expect(box.center.elevation == nil)
        let off = await box.center.run(.copy([source], to: protected))
        #expect(off.errors.map(\.code) == [EACCES])
        // On, but the user cancels the dialog: the same error, asked once.
        let prompt = Prompt(nil)
        box.center.elevation = prompt.provider
        let cancelled = await box.center.run(.copy([source, box.file("other.txt")], to: protected))
        #expect(cancelled.errors.map(\.code) == [EACCES, EACCES])
        #expect(prompt.asked == 1)
        #expect(box.names(in: protected).isEmpty)
    }

    @Test func ordinaryOperationsNeverAsk() async {
        let source = box.file("report.txt")
        let prompt = Prompt(FakeAdministrator())
        box.center.elevation = prompt.provider
        #expect(await box.center.run(.copy([source], to: box.dir("Open"))).errors.isEmpty)
        #expect(await box.center.run(.trash([source])).errors.isEmpty)
        // Not a permission problem: a missing item.
        #expect(await box.center.run(.delete([box.work.appendingPathComponent("nope")])).errors.count == 1)
        #expect(prompt.asked == 0 && prompt.administrator?.operations.isEmpty == true)
    }

    @Test func aRefusalFromTheHelperIsReported() async {
        let source = box.file("report.txt")
        lock(protected)
        defer { unlock(protected) }
        let admin = FakeAdministrator()
        admin.refuseWith = EPERM                                    // e.g. system integrity protection
        box.center.elevation = Prompt(admin).provider
        let result = await box.center.run(.copy([source], to: protected))
        #expect(result.errors.map(\.code) == [EPERM])
        #expect(box.names(in: protected).isEmpty)
    }

    @Test func aLockedItemIsNotAnAdministratorMatter() {
        let item = box.file("locked.txt")
        chflags(item.path, UInt32(UF_IMMUTABLE))
        defer { chflags(item.path, 0) }
        let prompt = Prompt(FakeAdministrator())
        let ops = ElevatingFileOps(provider: prompt.provider, jobTitle: "test")
        #expect(ops.rename(item, to: box.work.appendingPathComponent("renamed.txt")) == EPERM)
        #expect(prompt.asked == 0)
    }

    @Test func trashFallsBackToTheUsersTrashOnThatVolume() throws {
        let item = box.file("stuck.txt", "s", in: protected)
        box.file("stuck.txt", "already there", in: box.trashDir)
        lock(protected)
        defer { unlock(protected) }
        let prompt = Prompt(FakeAdministrator())
        let ops = ElevatingFileOps(provider: prompt.provider, jobTitle: "test")
        let trashDir = box.trashDir
        ops.trashFolder = { _ in trashDir }
        let refused: TrashFunction = { _ in throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
        let landed = try ops.trash(item, with: refused)
        #expect(landed == trashDir.appendingPathComponent("stuck 2.txt"))     // never replaces what's in the Trash
        #expect(box.read(landed) == "s" && prompt.asked == 1)
        // No Trash on that volume: the original error stands.
        ops.trashFolder = { _ in nil }
        let other = box.file("other.txt", in: box.dir("Open"))
        #expect(throws: (any Error).self) { try ops.trash(other, with: refused) }
    }

    // MARK: What the helper will and won't do

    @Test func onlyResolvedAbsolutePathsAreAccepted() {
        for good in ["/a", "/Library/Fonts/x.ttf", "/Volumes/Disk 2/a b/.hidden"] { #expect(PrivilegedExecutor.isAcceptable(good), "\(good)") }
        for bad in ["", "/", "relative/path", "~/x", "/a/../b", "/a/./b", "/a//b", "/a/", "/a/..", "/a\0b",
                    "/" + String(repeating: "x", count: 2000)] {
            #expect(!PrivilegedExecutor.isAcceptable(bad), "\(bad.prefix(20))")
        }
        #expect(PrivilegedExecutor.perform(.remove(path: "/"), owner: getuid()) == EINVAL)
        #expect(PrivilegedExecutor.perform(.rename(from: box.work.path + "/../x", to: "/tmp/y"), owner: getuid()) == EINVAL)
        #expect(PrivilegedExecutor.perform(.copyFile(from: "/etc/hosts", to: "relative"), owner: getuid()) == EINVAL)
    }

    @Test func executorOperations() {
        let me = getuid()
        let a = box.file("a.txt", "a")
        let made = box.work.appendingPathComponent("Made")
        #expect(PrivilegedExecutor.perform(.makeDirectory(path: made.path, mode: 0o700), owner: me) == 0)
        #expect(FileOps.lstat(made).map { $0.st_mode & 0o777 } == 0o700)
        #expect(PrivilegedExecutor.perform(.copyFile(from: a.path, to: made.path + "/copy.txt"), owner: me) == 0)
        #expect(box.read(made.appendingPathComponent("copy.txt")) == "a")
        // A folder isn't a file: the app walks trees itself, one item at a time.
        #expect(PrivilegedExecutor.perform(.copyFile(from: made.path, to: box.work.path + "/Made2"), owner: me) == EISDIR)
        // Rename never replaces.
        let b = box.file("b.txt", "b")
        #expect(PrivilegedExecutor.perform(.rename(from: a.path, to: b.path), owner: me) == EEXIST)
        #expect(PrivilegedExecutor.perform(.rename(from: a.path, to: box.work.path + "/c.txt"), owner: me) == 0)
        #expect(box.read(b) == "b")
        #expect(PrivilegedExecutor.perform(.remove(path: made.path), owner: me) == 0)
        #expect(!FileManager.default.fileExists(atPath: made.path))
    }

    @Test func symlinksAreCopiedNotFollowed() throws {
        let secret = box.file("secret.txt", "secret")
        let link = box.work.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let copy = box.work.appendingPathComponent("copy")
        #expect(PrivilegedExecutor.perform(.copyFile(from: link.path, to: copy.path), owner: getuid()) == 0)
        #expect(FileOps.lstat(copy).map(FileOps.isSymlink) == true)
    }

    @Test func attributeWritesAreLimitedToPermissionsAccessAndLock() {
        let item = box.file("a.txt")
        let wanted = ItemAttributes(extensionHidden: true, permissions: 0o640, comment: "from the helper", stationery: true)
        #expect(PrivilegedExecutor.perform(.writeAttributes(path: item.path, attributes: wanted), owner: getuid()) == 0)
        let now = ItemAttributes.read(item, fields: ItemAttributes(extensionHidden: false, permissions: 0, stationery: false))
        #expect(now.permissions == 0o640)
        #expect(now.extensionHidden == false && now.stationery == false)      // not the helper's business
        #expect(getxattr(item.path, "com.apple.metadata:kMDItemFinderComment", nil, 0, 0, 0) < 0)
    }

    @Test func requestsSurviveTheTripToTheHelper() throws {
        let all: [PrivilegedOperation] = [
            .rename(from: "/a", to: "/b"), .makeDirectory(path: "/a", mode: 0o755), .copyFile(from: "/a", to: "/b"),
            .copyDirectoryMetadata(from: "/a", to: "/b"), .remove(path: "/a"),
            .writeAttributes(path: "/a", attributes: ItemAttributes(locked: false, permissions: 0o644, accessList: "")),
        ]
        for op in all {
            #expect(try JSONDecoder().decode(PrivilegedOperation.self, from: JSONEncoder().encode(op)) == op)
        }
        // Anything else isn't a request.
        #expect((try? JSONDecoder().decode(PrivilegedOperation.self, from: Data(#"{"run":{"command":"rm -rf /"}}"#.utf8))) == nil)
    }

    // MARK: Who the helper talks to

    @Test func requirementsNameTheIdentifierAndTeam() {
        #expect(PrivilegedHelper.helperIdentifier(forApp: "io.github.emkey1.Foray") == "io.github.emkey1.Foray.helper")
        #expect(PrivilegedHelper.appIdentifier(forHelper: "io.github.emkey1.Foray.dev.helper") == "io.github.emkey1.Foray.dev")
        #expect(PrivilegedHelper.appIdentifier(forHelper: "foray-helper") == nil)
        #expect(PrivilegedHelper.requirement(identifier: "io.github.emkey1.Foray", team: "UYU5FM4LQ4")
            == #"identifier "io.github.emkey1.Foray" and anchor apple generic and certificate leaf[subject.OU] = "UYU5FM4LQ4""#)
        // Nothing that could change the meaning of the requirement gets in.
        #expect(PrivilegedHelper.requirement(identifier: #"x" or anchor trusted or identifier "y"#, team: "UYU5FM4LQ4") == nil)
        #expect(PrivilegedHelper.requirement(identifier: "io.github.emkey1.Foray", team: "") == nil)
        // And it's a requirement macOS accepts.
        var parsed: SecRequirement?
        let text = PrivilegedHelper.requirement(identifier: "io.github.emkey1.Foray", team: "UYU5FM4LQ4")!
        #expect(SecRequirementCreateWithString(text as CFString, [], &parsed) == errSecSuccess)
    }

    @Test func anAuthorizationWithoutTheRightIsRefused() {
        #expect(!PrivilegedHelper.isAuthorized(Data()))
        #expect(!PrivilegedHelper.isAuthorized(Data(repeating: 0, count: 32)))
        // A real authorization that nobody authenticated for: still no.
        var auth: AuthorizationRef?
        #expect(AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess)
        var form = AuthorizationExternalForm()
        #expect(AuthorizationMakeExternalForm(auth!, &form) == errAuthorizationSuccess)
        #expect(!PrivilegedHelper.isAuthorized(withUnsafeBytes(of: &form) { Data($0) }))
        AuthorizationFree(auth!, [.destroyRights])
    }
}
