import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel

/// Trash folders and Put Back records. Uses private folders only, never the real Trash.
@Suite(.serialized) struct TrashTests {
    /// A volume Trash `.DS_Store` written by `FileManager.trashItem` on a disk image (macOS 26.6):
    /// A/a1, A/a2, B/b1 and a1 (renamed "a1 20-11-12-745" in the Trash) were trashed. zlib + base64.
    static let fixture = """
    7Zi7TsMwFIb/42aIxIBHRr8AamNRsYaobIiFF6ARD1BBu+fR68sfFJK0XSt6Psn+HNnHl8WXAJDm8FUBFkCJbImFGUqmCWbQQGIfh5/9dygvsMTLXMAVEudusEW127dvf+a/HNS8syZ9B98nO3is8BhKVcp9yJ/xhPWgL0n9XG4/HiHan5yTH0X45HayioYR7WgVbRpDURRFuU0kq7w730xRlBsk7g+OrukuW1hv6GIQY2lH13SXLWxn6IIuaUs7uqa7bG5awseHcOT+8SKWdnQNRVFmWGTZeP6/nn7/K4ryj5Fi87Fp8PsgmBDPWhfSZx8AnuaYXgJM/qf20MfqRUBRro8j
    """

    static func fixtureData() throws -> Data {
        let compressed = try #require(Data(base64Encoded: fixture.trimmingCharacters(in: .whitespacesAndNewlines)))
        return try (compressed as NSData).decompressed(using: .zlib) as Data
    }

    @Test func parsesFinderPutBackRecords() throws {
        let records = try DSStore.records(in: try Self.fixtureData())
        var location: [String: String] = [:], name: [String: String] = [:]
        for r in records {
            if case .ustr(let s) = r.value, r.code == "ptbL" { location[r.name] = s }
            if case .ustr(let s) = r.value, r.code == "ptbN" { name[r.name] = s }
        }
        #expect(location == ["a1": "/A/", "a2": "/A/", "b1": "/B/", "a1 20-11-12-745": "/"])
        #expect(name["a1 20-11-12-745"] == "a1")
    }

    @Test func rejectsGarbage() throws {
        #expect(throws: DSStore.Malformed.self) { try DSStore.records(in: Data("not a store".utf8)) }
        var data = try Self.fixtureData()
        data[0x14] = 0xff   // corrupt the allocator offset: no crash, just an error
        _ = try? DSStore.records(in: data)
        #expect(DSStore.records(at: URL(fileURLWithPath: "/nonexistent/.DS_Store")).isEmpty)
        // Every truncation fails cleanly.
        let full = try Self.fixtureData()
        for length in stride(from: 0, to: full.count, by: 97) { _ = try? DSStore.records(in: full.prefix(length)) }
    }

    @Test func putBackDestinationsAreRelativeToTheTrashesVolume() throws {
        let volume = FileManager.default.temporaryDirectory.appendingPathComponent("rf-trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: volume) }
        let trash = TrashFolders.folder(onVolume: volume)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Self.fixtureData().write(to: trash.appendingPathComponent(".DS_Store"))
        let items = ["a1", "a2", "b1", "a1 20-11-12-745", "unknown"].map { trash.appendingPathComponent($0) }
        let d = TrashFolders.putBackDestinations(for: items)
        #expect(d[items[0]]?.path == volume.appendingPathComponent("A/a1").path)
        #expect(d[items[2]]?.path == volume.appendingPathComponent("B/b1").path)
        #expect(d[items[3]]?.path == volume.appendingPathComponent("a1").path)
        #expect(d[items[4]] == nil)
        #expect(TrashFolders.volumeRoot(ofTrash: URL(fileURLWithPath: "/Users/x/.Trash")).path == "/")
    }

    @Test func contentsMergeEveryTrash() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rf-trashmerge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent(".Trash"), other = TrashFolders.folder(onVolume: base.appendingPathComponent("V"))
        for d in [home, other] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        FileManager.default.createFile(atPath: home.appendingPathComponent("h.txt").path, contents: nil)
        FileManager.default.createFile(atPath: other.appendingPathComponent("v.txt").path, contents: nil)
        TrashFolders.overrideForTesting([home, other])
        defer { TrashFolders.overrideForTesting(nil) }
        #expect(TrashFolders.all() == [home, other])
        #expect(TrashFolders.home == home)
        #expect(TrashFolders.isTopLevelItem(other.appendingPathComponent("v.txt"), in: TrashFolders.all()))
        #expect(!TrashFolders.isTopLevelItem(base.appendingPathComponent("v.txt"), in: TrashFolders.all()))

        var names: [String] = []
        for await event in TrashContents.observe() {
            if case .complete(let items) = event { names = items.map(\.name).sorted(); break }
        }
        #expect(names == ["h.txt", "v.txt"])

        // An unreadable home Trash fails the location (so the Full Disk Access note shows).
        var failed = false
        for await event in TrashContents.observe([base.appendingPathComponent("missing"), other]) {
            if case .failed = event { failed = true; break }
        }
        #expect(failed)
    }

    /// The real `trashItem` on a disk image (its own Trash, not the user's): Finder's record is
    /// readable. Opt-in (RF_FS_MATRIX=1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RF_FS_MATRIX"] == "1"))
    func systemTrashRecordsAreRead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rf-trashimg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("t.dmg"), mount = dir.appendingPathComponent("mnt")
        try hdiutil(["create", "-size", "20m", "-fs", "APFS", "-volname", "RFTrash", image.path])
        try hdiutil(["attach", "-nobrowse", "-noverify", "-mountpoint", mount.path, image.path])
        defer { try? hdiutil(["detach", "-force", mount.path]) }
        let original = mount.appendingPathComponent("Sub/report.txt")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: original.path, contents: Data("r".utf8))
        var trashed: NSURL?
        try FileManager.default.trashItem(at: original, resultingItemURL: &trashed)
        let inTrash = try #require(trashed as URL?)
        func real(_ u: URL) -> String { u.path.withCString { p in realpath(p, nil).map { defer { free($0) }; return String(cString: $0) } } ?? u.path }
        #expect(real(inTrash.deletingLastPathComponent()) == real(TrashFolders.folder(onVolume: mount)), "\(inTrash.path)")
        // The record is written asynchronously.
        var found: URL?
        for _ in 0..<50 where found == nil {
            found = TrashFolders.putBackDestinations(for: [inTrash])[inTrash]
            if found == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(found.map(real) == real(original.deletingLastPathComponent()) + "/report.txt", "\(String(describing: found))")
    }

    private func hdiutil(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "hdiutil", code: Int(p.terminationStatus)) }
    }
}

struct CloudLocationTests {
    @Test func listsICloudAndProvidersByFriendlyName() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rf-cloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let storage = base.appendingPathComponent("CloudStorage"), icloud = base.appendingPathComponent("CloudDocs")
        for d in ["GoogleDrive-me@example.com", "Dropbox", "OneDrive-Personal", ".hidden"] {
            try FileManager.default.createDirectory(at: storage.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: storage.appendingPathComponent("stray.txt").path, contents: nil)
        #expect(CloudLocations.places(cloudStorage: storage, iCloud: icloud).map(\.name) == ["Dropbox", "Google Drive", "OneDrive"])
        try FileManager.default.createDirectory(at: icloud, withIntermediateDirectories: true)
        let places = CloudLocations.places(cloudStorage: storage, iCloud: icloud)
        #expect(places.first?.name == "iCloud Drive" && places.first?.isICloud == true)
    }

    @Test func recognizesCloudPaths() {
        #expect(CloudLocations.isCloudItem(CloudLocations.cloudStorageURL.appendingPathComponent("Dropbox/a.txt")))
        #expect(CloudLocations.isCloudItem(CloudLocations.iCloudDriveURL.appendingPathComponent("Notes/b.txt")))
        #expect(!CloudLocations.isCloudItem(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/c.txt")))
        #expect(CloudLocations.displayName(providerFolder: "Box-Box") == "Box")
    }
}

struct NetworkMountTests {
    @Test func normalizesAddresses() {
        #expect(NetworkMounts.normalize("server")?.absoluteString == "smb://server")
        #expect(NetworkMounts.normalize("  nas.local/Media ")?.absoluteString == "smb://nas.local/Media")
        #expect(NetworkMounts.normalize("afp://old-mac/Share")?.scheme == "afp")
        #expect(NetworkMounts.normalize("https://dav.example.com/files")?.host == "dav.example.com")
        #expect(NetworkMounts.normalize("") == nil)
        #expect(NetworkMounts.normalize("gopher://x") == nil)
        #expect(NetworkMounts.normalize("smb://") == nil)
    }

    @Test func bonjourNamesBecomeServiceURLs() {
        #expect(NetworkMounts.url(forSMBService: "My Mac")?.absoluteString == "smb://My%20Mac._smb._tcp.local")
        #expect(NetworkMounts.Failure(status: EAUTH).errorDescription?.contains("password") == true)
    }
}

struct TestSafetyTests {
    @Test func testRunsNeverUseTheRealAppSupportFolder() {
        #expect(TestEnvironment.isActive)
        #expect(!AppSupportStore.shared.directory.path.contains("Application Support"))
    }
}
