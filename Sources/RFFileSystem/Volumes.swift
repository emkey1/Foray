import AppKit
import Foundation
import RFModel

public struct VolumeInfo: Hashable, Sendable, Identifiable {
    public let url: URL
    public let name: String
    public let isEjectable: Bool
    public let isInternal: Bool
    public let isLocal: Bool
    public let isStartup: Bool
    public var id: URL { url }
}

/// Mounted volumes for the sidebar and Computer location (DESIGN.md §5.9).
public enum Volumes {
    static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey,
        .volumeIsLocalKey, .volumeIsBrowsableKey,
    ]

    public static func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { return nil }
            return VolumeInfo(
                url: url, name: v.volumeLocalizedName ?? url.lastPathComponent,
                isEjectable: v.volumeIsEjectable == true || v.volumeIsRemovable == true,
                isInternal: v.volumeIsInternal == true, isLocal: v.volumeIsLocal != false, isStartup: url.path == "/")
        }
        .sorted { ($0.isStartup ? 0 : 1, $0.name) < ($1.isStartup ? 0 : 1, $1.name) }
    }

    /// Calls `handler` on the main queue whenever volumes mount, unmount or are renamed.
    @MainActor
    public static func observeChanges(_ handler: @escaping @MainActor () -> Void) -> [NSObjectProtocol] {
        let center = NSWorkspace.shared.notificationCenter
        return [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification]
            .map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { handler() }
                }
            }
    }

}

/// Names and identities that need filesystem access (kept out of RFModel).
public enum LocationInfo {
    public static func displayName(_ location: Location) -> String {
        switch location {
        case .folder(let url): FileManager.default.displayName(atPath: url.path)
        case .computer: Host.current().localizedName ?? "Computer"
        case .search, .trash: location.fallbackTitle
        }
    }

    /// Key for per-folder settings: volume UUID + file ID, which survive renames.
    public static func folderKey(_ url: URL) -> FolderKey? {
        guard let v = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .fileIdentifierKey]) else { return nil }
        return FolderKey(volumeUUID: v.volumeUUIDString ?? "", fileID: v.fileIdentifier ?? 0, path: url.standardizedFileURL.path)
    }

    /// Path components from the volume root down to `url`, for the path bar.
    public static func pathChain(_ url: URL) -> [URL] {
        var chain: [URL] = []
        var current = url.standardizedFileURL
        while true {
            chain.insert(current, at: 0)
            let isVolumeRoot = (try? current.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
            if isVolumeRoot || current.path == "/" { break }
            current = current.deletingLastPathComponent()
        }
        return chain
    }
}
