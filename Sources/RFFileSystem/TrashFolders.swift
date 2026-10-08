import Foundation
import RFModel
import Synchronization

/// The user's Trash folders and Put Back records (DESIGN.md §5.7). Each volume has its own Trash;
/// the Trash location shows them together.
public enum TrashFolders {
    /// Tests substitute private folders so they never read or change the real Trash.
    private static let override = Mutex<[URL]?>(nil)
    public static func overrideForTesting(_ folders: [URL]?) { override.withLock { $0 = folders } }

    public static var home: URL {
        override.withLock { $0?.first } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    /// `<volume>/.Trashes/<uid>`, where items trashed on that volume go.
    public static func folder(onVolume volume: URL) -> URL {
        volume.appendingPathComponent(".Trashes", isDirectory: true).appendingPathComponent(String(getuid()), isDirectory: true)
    }

    /// The home Trash plus every mounted volume's Trash that exists.
    public static func all() -> [URL] {
        if let folders = override.withLock({ $0 }) { return folders }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return [home] + volumes.filter { $0.path != "/" }.map(folder(onVolume:)).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Is `url` an item directly inside one of `folders` (something Put Back applies to)?
    public static func isTopLevelItem(_ url: URL, in folders: [URL]) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        return folders.contains { $0.standardizedFileURL.path == parent }
    }

    /// Where Put Back returns each item, from the Trash's `.DS_Store` records (written by Finder and by
    /// `FileManager.trashItem`; M0 S4). Items without a record are left out.
    public static func putBackDestinations(for items: [URL]) -> [URL: URL] {
        var result: [URL: URL] = [:]
        let byFolder = Dictionary(grouping: items) { $0.deletingLastPathComponent() }
        for (folder, items) in byFolder {
            let records = DSStore.records(at: folder.appendingPathComponent(".DS_Store"))
            var location: [String: String] = [:], originalName: [String: String] = [:]
            for r in records {
                guard case .ustr(let s) = r.value else { continue }
                if r.code == "ptbL" { location[r.name] = s }
                if r.code == "ptbN" { originalName[r.name] = s }
            }
            let root = volumeRoot(ofTrash: folder)
            for item in items {
                let name = item.lastPathComponent
                guard let parent = location[name] ?? location[name.precomposedStringWithCanonicalMapping] else { continue }
                let relative = parent.hasPrefix("/") ? String(parent.dropFirst()) : parent
                let dir = relative.isEmpty ? root : root.appendingPathComponent(relative, isDirectory: true)
                result[item] = dir.appendingPathComponent(originalName[name] ?? name)
            }
        }
        return result
    }

    /// `ptbL` paths are relative to the volume the Trash is on.
    static func volumeRoot(ofTrash folder: URL) -> URL {
        let parent = folder.deletingLastPathComponent()
        if parent.lastPathComponent == ".Trashes" { return parent.deletingLastPathComponent() }
        return URL(fileURLWithPath: "/", isDirectory: true)
    }
}

/// The Trash location's contents: every Trash folder, kept current.
public enum TrashContents {
    public static func observe(_ folders: [URL] = TrashFolders.all()) -> AsyncStream<FolderEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: Void.self) { group in
                    let state = Merge(count: folders.count)
                    for (i, folder) in folders.enumerated() {
                        group.addTask {
                            for await event in FolderContents.observe(folder) {
                                if Task.isCancelled { break }
                                if let merged = await state.update(i, event) { continuation.yield(merged) }
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private actor Merge {
        var items: [[FileItem]]
        var done: [Bool]
        var failure: FileSystemError?

        init(count: Int) {
            items = Array(repeating: [], count: count)
            done = Array(repeating: false, count: count)
        }

        /// The first folder is the home Trash: if it can't be read, the location fails (so the
        /// Full Disk Access explanation shows). Other Trashes that fail are just left out.
        func update(_ i: Int, _ event: FolderEvent) -> FolderEvent? {
            switch event {
            case .partial(let list):
                items[i] = list
            case .complete(let list):
                items[i] = list
                done[i] = true
            case .failed(let error):
                items[i] = []
                done[i] = true
                if i == 0 { failure = error }
            }
            if let failure { return .failed(failure) }
            let all = items.flatMap { $0 }
            return done.allSatisfy { $0 } ? .complete(all) : .partial(all)
        }
    }
}
