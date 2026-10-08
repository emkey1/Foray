import Foundation
import RFModel

/// Everything about a location that needs filesystem access, gathered in one call off the main
/// thread (on the location's volume queue, so a hung mount doesn't block the UI).
public struct LocationDetails: Sendable {
    public var displayName: String
    /// Volume root first, the location itself last.
    public var pathChain: [(url: URL, name: String)]
    public var availableCapacity: Int64?
    public var folderKey: FolderKey?

    public static func fallback(_ location: Location) -> LocationDetails {
        LocationDetails(displayName: location.fallbackTitle, pathChain: [], availableCapacity: nil, folderKey: nil)
    }
}

extension LocationInfo {
    public static func details(for location: Location) async -> LocationDetails {
        guard let url = location.folderURL else {
            return LocationDetails(displayName: displayName(location), pathChain: [], availableCapacity: nil, folderKey: nil)
        }
        return await withCheckedContinuation { continuation in
            DirectoryLoader.shared.queue(for: url).async {
                let chain = pathChain(url).map { (url: $0, name: FileManager.default.displayName(atPath: $0.path)) }
                let capacity = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage
                continuation.resume(returning: LocationDetails(
                    displayName: displayName(location), pathChain: chain, availableCapacity: capacity,
                    folderKey: folderKey(url)))
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
