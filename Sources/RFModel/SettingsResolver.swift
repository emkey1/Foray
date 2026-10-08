import Foundation

/// Identifies a folder for per-folder settings so they survive renames and moves (DESIGN.md §3.3).
public struct FolderKey: Hashable, Codable, Sendable {
    public var volumeUUID: String
    public var fileID: UInt64
    /// Last known path; used as a fallback when the volume can't be identified.
    public var path: String

    public init(volumeUUID: String, fileID: UInt64, path: String) {
        self.volumeUUID = volumeUUID
        self.fileID = fileID
        self.path = path
    }

    public func matches(_ other: FolderKey) -> Bool {
        if !volumeUUID.isEmpty && volumeUUID == other.volumeUUID { return fileID == other.fileID }
        return path == other.path
    }
}

public enum SettingsModel: String, Codable, Sendable {
    /// Changes update the location class's default; per-folder settings only when pinned.
    case sameEverywhere
    /// Every change creates a per-folder override (Finder-like, but predictable).
    case perFolder
}

public enum SettingsSource: Hashable, Sendable {
    case folder(FolderKey)
    case classDefault(LocationClass)
}

/// All view settings: class defaults plus per-folder overrides, and the rules that pick one.
public struct ViewSettingsDatabase: Codable, Sendable {
    public var model: SettingsModel = .sameEverywhere
    public var classDefaults: [LocationClass: ViewSettings] = [:]
    public var folderOverrides: [FolderOverride] = []

    public struct FolderOverride: Codable, Sendable {
        public var key: FolderKey
        public var settings: ViewSettings
    }

    public init() {}

    public static func builtInDefault(for cls: LocationClass) -> ViewSettings {
        switch cls {
        case .searchResults:
            var s = ViewSettings(presentation: Presentation(mode: .list))
            s.presentation.list.columns = [ListColumnSpec(.name), ListColumnSpec(.folder), ListColumnSpec(.dateModified),
                                           ListColumnSpec(.size), ListColumnSpec(.kind)]
            return s
        case .recents:
            var s = ViewSettings(presentation: Presentation(mode: .list))
            s.arrangement.sort = [SortDescriptor(.dateLastOpened, ascending: false)]
            s.arrangement.foldersFirst = false
            s.presentation.list.columns = [ListColumnSpec(.name), ListColumnSpec(.dateLastOpened), ListColumnSpec(.folder),
                                           ListColumnSpec(.size), ListColumnSpec(.kind)]
            return s
        default:
            return ViewSettings()
        }
    }

    public func override(for key: FolderKey?) -> FolderOverride? {
        guard let key else { return nil }
        return folderOverrides.first { $0.key.matches(key) }
    }

    /// Effective settings: folder override ?? class default ?? built-in default.
    public func resolve(_ cls: LocationClass, folder: FolderKey?) -> (ViewSettings, SettingsSource) {
        if let o = override(for: folder) { return (o.settings, .folder(o.key)) }
        return (classDefaults[cls] ?? Self.builtInDefault(for: cls), .classDefault(cls))
    }

    /// Records a change the user made while viewing a location. Returns where it was stored.
    @discardableResult
    public mutating func update(_ settings: ViewSettings, cls: LocationClass, folder: FolderKey?) -> SettingsSource {
        if let folder, let i = folderOverrides.firstIndex(where: { $0.key.matches(folder) }) {
            folderOverrides[i].settings = settings
            folderOverrides[i].key.path = folder.path
            return .folder(folderOverrides[i].key)
        }
        if model == .perFolder, let folder {
            folderOverrides.append(FolderOverride(key: folder, settings: settings))
            return .folder(folder)
        }
        classDefaults[cls] = settings
        return .classDefault(cls)
    }

    /// View › Remember Settings for This Folder.
    public mutating func pin(_ settings: ViewSettings, folder: FolderKey) {
        if let i = folderOverrides.firstIndex(where: { $0.key.matches(folder) }) {
            folderOverrides[i].settings = settings
        } else {
            folderOverrides.append(FolderOverride(key: folder, settings: settings))
        }
    }

    /// "Forget": the folder goes back to its class default.
    public mutating func unpin(_ folder: FolderKey) {
        folderOverrides.removeAll { $0.key.matches(folder) }
    }
}
