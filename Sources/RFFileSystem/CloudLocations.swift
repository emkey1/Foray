import Foundation

/// iCloud Drive and File Provider locations (Dropbox, Google Drive, OneDrive, Box…) for the
/// sidebar, and download/evict for their items (DESIGN.md §5.9).
public enum CloudLocations {
    public struct Place: Hashable, Sendable {
        public let name: String
        public let url: URL
        public let isICloud: Bool
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var iCloudDriveURL: URL { home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true) }
    public static var cloudStorageURL: URL { home.appendingPathComponent("Library/CloudStorage", isDirectory: true) }

    /// iCloud Drive (if set up) plus each File Provider folder, by display name.
    public static func places(cloudStorage: URL = cloudStorageURL, iCloud: URL = iCloudDriveURL) -> [Place] {
        var out: [Place] = []
        if FileManager.default.fileExists(atPath: iCloud.path) { out.append(Place(name: "iCloud Drive", url: iCloud, isICloud: true)) }
        let providers = (try? FileManager.default.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        for url in providers.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            out.append(Place(name: displayName(providerFolder: url.lastPathComponent), url: url, isICloud: false))
        }
        return out
    }

    /// "GoogleDrive-me@example.com" → "Google Drive"; "OneDrive-Personal" → "OneDrive"; "Dropbox" → "Dropbox".
    public static func displayName(providerFolder name: String) -> String {
        let base = name.split(separator: "-", maxSplits: 1).first.map(String.init) ?? name
        let known = ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box", "pCloudDrive": "pCloud Drive"]
        return known[base] ?? base
    }

    /// Inside iCloud Drive or a File Provider folder.
    public static func isCloudItem(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(cloudStorageURL.path + "/") || path.hasPrefix(home.appendingPathComponent("Library/Mobile Documents").path + "/")
    }

    /// Starts downloading every not-yet-downloaded file at or under `url`. Returns how many were requested.
    @discardableResult
    public static func download(_ url: URL) async -> Int {
        var urls: [URL] = []
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for await event in TreeWalker.walk(url, options: .init(includeHidden: false)) {
                if case .items(let items) = event { urls += items.filter { $0.flags.contains(.dataless) }.map(\.url) }
            }
        } else {
            urls = [url]
        }
        for u in urls { try? FileManager.default.startDownloadingUbiquitousItem(at: u) }
        return urls.count
    }

    /// Removes the local copy, keeping the item in the cloud.
    public static func removeDownload(_ url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}
