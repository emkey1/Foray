import Foundation
import Testing
import UniformTypeIdentifiers

@testable import RFFileSystem
@testable import RFModel

/// A fresh temporary directory per test, removed afterwards.
final class TempDir: @unchecked Sendable {  // immutable after init
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("rf-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ name: String, _ contents: String = "x", mode: Int? = nil) -> URL {
        let u = url.appendingPathComponent(name)
        FileManager.default.createFile(atPath: u.path, contents: Data(contents.utf8),
                                       attributes: mode.map { [.posixPermissions: $0] })
        return u
    }

    @discardableResult
    func dir(_ name: String) throws -> URL {
        let u = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

@Suite struct DirectoryLoaderTests {
    @Test func listsTheSameEntriesAsFileManager() async throws {
        let tmp = try TempDir()
        for i in 0..<1_500 { tmp.file("file \(i).txt", String(repeating: "a", count: i)) }
        try tmp.dir("sub")
        let items = try await DirectoryLoader.shared.loadAll(tmp.url)
        let expected = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        #expect(Set(items.map(\.name)) == Set(expected))
        let f = try #require(items.first { $0.name == "file 42.txt" })
        #expect(f.size == 42)
        #expect(f.contentType == .plainText)
        #expect(f.url == tmp.url.appendingPathComponent("file 42.txt"))
        let attrs = try FileManager.default.attributesOfItem(atPath: f.url.path)
        #expect(f.id.inode == (attrs[.systemFileNumber] as! NSNumber).uint64Value)
        #expect(abs(f.modified!.timeIntervalSince(attrs[.modificationDate] as! Date)) < 0.001)
    }

    @Test func derivesTypesAndFlags() async throws {
        let tmp = try TempDir()
        tmp.file(".dotfile")
        tmp.file("script", "#!/bin/sh", mode: 0o755)
        tmp.file("photo.JPG")
        tmp.file("unknown.zzqq")
        try tmp.dir("Folder")
        try tmp.dir("Thing.app")
        try FileManager.default.createSymbolicLink(at: tmp.url.appendingPathComponent("link"), withDestinationURL: tmp.url)
        let items = Dictionary(uniqueKeysWithValues: try await DirectoryLoader.shared.loadAll(tmp.url).map { ($0.name, $0) })

        #expect(items[".dotfile"]!.flags.contains(.hidden))
        #expect(items["script"]!.contentType == .unixExecutable)
        #expect(items["script"]!.flags.contains(.executable))
        #expect(items["photo.JPG"]!.contentType == .jpeg)
        #expect(items["unknown.zzqq"]!.contentType.isDynamic)
        #expect(items["Folder"]!.contentType == .folder)
        #expect(items["Folder"]!.isNavigableFolder)
        #expect(items["Folder"]!.size == nil)
        #expect(items["Thing.app"]!.flags.contains(.package))
        #expect(!items["Thing.app"]!.isNavigableFolder)
        #expect(items["link"]!.flags.contains(.symlink))
    }

    @Test func streamsLargeDirectoriesInBatches() async throws {
        let tmp = try TempDir()
        for i in 0..<3_000 { tmp.file("f\(i)") }
        var batches = 0, total = 0
        for try await batch in DirectoryLoader.shared.load(tmp.url, firstBatch: 100) {
            if batches == 0 { #expect(batch.count == 100) }
            batches += 1
            total += batch.count
        }
        #expect(total == 3_000)
        #expect(batches >= 2)
    }

    @Test func reportsMissingAndPermissionErrors() async throws {
        let tmp = try TempDir()
        await #expect(throws: FileSystemError.self) {
            _ = try await DirectoryLoader.shared.loadAll(tmp.url.appendingPathComponent("nope"))
        }
        let locked = try tmp.dir("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        do {
            _ = try await DirectoryLoader.shared.loadAll(locked)
            Issue.record("expected permission error")
        } catch let e as FileSystemError {
            #expect(e.isPermissionDenied)
        }
    }

    @Test func statSingleItem() throws {
        let tmp = try TempDir()
        let u = tmp.file("one.pdf", "12345")
        let item = try #require(DirectoryLoader.shared.stat(u))
        #expect(item.name == "one.pdf")
        #expect(item.size == 5)
        #expect(item.contentType == .pdf)
        #expect(item.url == u)
        #expect(DirectoryLoader.shared.stat(tmp.url.appendingPathComponent("gone")) == nil)
    }
}

@Suite struct FolderContentsTests {
    @Test func picksUpChangesAfterInitialLoad() async throws {
        let tmp = try TempDir()
        tmp.file("before.txt")
        final class Seen: @unchecked Sendable { var names: [Set<String>] = [] }
        let seen = Seen()
        let task = Task {
            for await event in FolderContents.observe(tmp.url) {
                if case .complete(let items) = event { seen.names.append(Set(items.map(\.name))) }
            }
        }
        defer { task.cancel() }
        #expect(await eventually { seen.names.count == 1 })
        #expect(seen.names.first == ["before.txt"])
        tmp.file("after.txt")
        #expect(await eventually { seen.names.last == ["before.txt", "after.txt"] })
    }
}

@Suite struct LocationInfoTests {
    @Test func folderKeySurvivesRename() throws {
        let tmp = try TempDir()
        let a = try tmp.dir("a")
        let key = try #require(LocationInfo.folderKey(a))
        let b = tmp.url.appendingPathComponent("b")
        try FileManager.default.moveItem(at: a, to: b)
        let renamed = try #require(LocationInfo.folderKey(b))
        #expect(key.matches(renamed))
        #expect(renamed.path != key.path)
    }

    @Test func startupVolumeIsListedFirst() {
        #expect(Volumes.mounted().first?.isStartup == true)
    }
}

/// Waits for `fired` to become true, polling, up to `seconds`. FSEvents delivery takes 0.2–0.8 s
/// on an idle machine (LatencyProbe) and more under parallel test load.
func eventually(_ seconds: Double = 15, _ fired: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if fired() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return fired()
}

@Suite struct DirectoryWatcherTests {
    final class Flag: @unchecked Sendable { var value = false }

    @Test func firesForChangesInWatchedDirectory() async throws {
        let tmp = try TempDir()
        let flag = Flag()
        let watcher = DirectoryWatcher()
        let token = watcher.subscribe(tmp.url) { flag.value = true }
        defer { watcher.unsubscribe(token) }
        tmp.file("new.txt")  // no delay: subscribe() guarantees the stream is running
        #expect(await eventually { flag.value })
    }

    /// Regression: with one shared stream, removing a subscriber restarted the stream and replayed
    /// history into the remaining folders, causing spurious reloads. Checked structurally (the other
    /// folder's stream is untouched) because FSEvents delivery timing under load isn't predictable.
    @Test func unsubscribingOneFolderDoesNotDisturbAnother() async throws {
        let a = try TempDir(), b = try TempDir()
        let watcher = DirectoryWatcher()
        let tokenA = watcher.subscribe(a.url) {}
        let tokenB = watcher.subscribe(b.url) {}
        let streamA = try #require(watcher.streamIdentity(for: a.url))
        watcher.unsubscribe(tokenB)
        #expect(watcher.watchedPathCount == 1)
        #expect(watcher.streamIdentity(for: a.url) == streamA)
        #expect(watcher.streamIdentity(for: b.url) == nil)
        let fired = Flag()
        let tokenA2 = watcher.subscribe(a.url) { fired.value = true }
        #expect(watcher.streamIdentity(for: a.url) == streamA)   // second subscriber shares it
        a.file("still-watched.txt")
        #expect(await eventually { fired.value })
        watcher.unsubscribe(tokenA)
        watcher.unsubscribe(tokenA2)
    }

    /// Writes next to the watched folder (in its parent) must not count as changes to it.
    @Test func changesInParentDirectoryAreIgnored() async throws {
        let base = try TempDir()
        let watched = try base.dir("watched")
        let watcher = DirectoryWatcher()
        let fired = Flag()
        let token = watcher.subscribe(watched) { fired.value = true }
        defer { watcher.unsubscribe(token) }
        repeat {
            fired.value = false
            try await Task.sleep(for: .milliseconds(1500))
        } while fired.value
        base.file("sibling.txt")
        try base.dir("sibling-dir")
        try await Task.sleep(for: .milliseconds(800))
        #expect(!fired.value)
    }

    @Test func subscribersToTheSameFolderShareOneStream() throws {
        let tmp = try TempDir()
        let watcher = DirectoryWatcher()
        let t1 = watcher.subscribe(tmp.url) {}
        let t2 = watcher.subscribe(tmp.url) {}
        #expect(watcher.watchedPathCount == 1)
        watcher.unsubscribe(t1)
        watcher.unsubscribe(t2)
    }
}
