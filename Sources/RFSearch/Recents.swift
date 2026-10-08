import CoreServices
import Foundation
import RFFileSystem
import RFModel

/// The Recents location: files opened in the last `days` days, from Spotlight, kept current.
/// Folders, apps, hidden items and anything in ~/Library are left out, like Finder.
public enum Recents {
    public static let days = 30

    public static var queryString: String {
        "kMDItemLastUsedDate >= $time.today(-\(days)) && kMDItemContentType != \"public.folder\""
            + " && kMDItemContentTypeTree != \"com.apple.application-bundle\""
    }

    public static func observe(scopes: [URL]? = nil) -> AsyncStream<FolderEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var byPath: [String: FileItem] = [:]
                var gathering = true
                let runner = SpotlightRunner()
                let spotlightScopes: [SpotlightRunner.Scope] = scopes.map { $0.map { .folder($0) } } ?? [.localComputer]
                for await event in runner.run(queryString, scopes: spotlightScopes) {
                    if Task.isCancelled { break }
                    switch event {
                    case .added(let paths), .changed(let paths):
                        for item in items(paths.filter(isWanted)) { byPath[item.url.path] = item }
                    case .removed(let paths):
                        for p in paths { byPath[p] = nil }
                    case .finishedGathering:
                        gathering = false
                    }
                    let all = Array(byPath.values)
                    continuation.yield(gathering ? .partial(all) : .complete(all))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path + "/"

    static func isWanted(_ path: String) -> Bool {
        !path.hasPrefix(library) && !path.contains("/.") && !path.hasPrefix("/System/") && !path.hasPrefix("/private/")
    }

    static func items(_ paths: [String]) -> [FileItem] {
        paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard let item = DirectoryLoader.shared.stat(url), !item.isNavigableFolder else { return nil }
            return item.with(lastOpened: LastOpened.read(url) ?? spotlightLastUsed(path))
        }
    }

    /// A few files have Spotlight's date but not the attribute.
    static func spotlightLastUsed(_ path: String) -> Date? {
        guard let md = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date
    }
}
