import Foundation
import RFModel
import Synchronization

/// Everything about a location that needs filesystem access, gathered in one call off the main
/// thread (on the location's volume queue, so a hung mount doesn't block the UI).
public struct LocationDetails: Sendable {
    public var displayName: String
    /// Volume root first, the location itself last.
    public var pathChain: [(url: URL, name: String)]
    public var folderKey: FolderKey?

    public static func fallback(_ location: Location) -> LocationDetails {
        LocationDetails(displayName: location.fallbackTitle, pathChain: [], folderKey: nil)
    }
}

/// Free space per volume. The lookup ("available for important usage", which matches Finder and
/// counts purgeable space) takes 17–170 ms, so it's cached briefly and never runs on a listing path.
private let capacityCache = Mutex<[String: (value: Int64, at: Date)]>([:])

extension LocationInfo {
    public static func details(for location: Location) async -> LocationDetails {
        guard let url = location.folderURL else {
            return LocationDetails(displayName: displayName(location), pathChain: [], folderKey: nil)
        }
        return await withCheckedContinuation { continuation in
            DirectoryLoader.shared.metadataQueue(for: url).async {
                let chain = pathChain(url).map { (url: $0, name: FileManager.default.displayName(atPath: $0.path)) }
                continuation.resume(returning: LocationDetails(
                    displayName: displayName(location), pathChain: chain, folderKey: folderKey(url)))
            }
        }
    }

    public static func availableCapacity(for url: URL) async -> Int64? {
        let key = DirectoryLoader.volumeKey(url)
        if let hit = capacityCache.withLock({ $0[key] }), Date().timeIntervalSince(hit.at) < 30 { return hit.value }
        return await withCheckedContinuation { continuation in
            DirectoryLoader.shared.metadataQueue(for: url).async {
                // "For important usage" counts space macOS can free up, which is what Finder shows,
                // but it reports 0 on disk images and some external and network disks. The plain
                // figure is always there, so show whichever is larger.
                let important = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage
                var fs = statfs()
                let plain: Int64? = statfs(url.path, &fs) == 0 ? Int64(fs.f_bavail) * Int64(fs.f_bsize) : nil
                let value: Int64? = switch (important, plain) {
                case let (i?, p?): max(i, p)
                case let (i?, nil): i
                case let (nil, p?): p
                default: nil
                }
                if let value { capacityCache.withLock { $0[key] = (value, Date()) } }
                continuation.resume(returning: value)
            }
        }
    }

    /// Volumes as items, for the Computer location.
    public static func volumeItems() -> [FileItem] {
        Volumes.mounted().enumerated().map { i, v in
            FileItem(id: FileID(device: -1, inode: UInt64(i)), url: v.url, name: v.name, contentType: .volume,
                     flags: [.directory, .mountPoint], size: nil)
        }
    }
}
