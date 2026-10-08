import AppKit
import RFFileSystem
import RFModel

/// App-wide state: view settings and the saved session. Broadcasts settings changes so every
/// tab showing a location with the same settings source updates live (DESIGN.md §3.3).
@MainActor
public final class AppModel {
    /// Replaceable so tests never touch the user's real settings.
    public static var shared = AppModel(store: .shared)

    private let store: AppSupportStore
    private static let settingsFile = "view-settings.json"
    private static let sessionFile = "session.json"

    public private(set) var settings: ViewSettingsDatabase
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var saveScheduled = false

    public init(store: AppSupportStore) {
        self.store = store
        settings = store.load(ViewSettingsDatabase.self, from: Self.settingsFile) ?? ViewSettingsDatabase()
    }

    // MARK: View settings

    func resolve(_ cls: LocationClass, folder: FolderKey?) -> (ViewSettings, SettingsSource) {
        settings.resolve(cls, folder: folder)
    }

    func record(_ s: ViewSettings, cls: LocationClass, folder: FolderKey?) {
        settings.update(s, cls: cls, folder: folder)
        settingsChanged()
    }

    func pin(_ s: ViewSettings, folder: FolderKey) {
        settings.pin(s, folder: folder)
        settingsChanged()
    }

    func unpin(_ folder: FolderKey) {
        settings.unpin(folder)
        settingsChanged()
    }

    func isPinned(_ folder: FolderKey?) -> Bool { settings.override(for: folder) != nil }

    func observeSettings(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    private func settingsChanged() {
        for handler in observers.values { handler() }
        guard !saveScheduled else { return }
        saveScheduled = true
        // Coalesce bursts (e.g. column resizing) into one write.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                self.saveScheduled = false
                self.store.save(self.settings, to: Self.settingsFile)
            }
        }
    }

    public func flush() { store.save(settings, to: Self.settingsFile) }

    // MARK: Session

    public struct Session: Codable {
        public struct Window: Codable {
            public var tabs: [Location]
            public var selectedTab: Int
            public var frame: String?
        }
        public var windows: [Window]
    }

    public func saveSession(_ session: Session) { store.save(session, to: Self.sessionFile) }
    public func loadSession() -> Session? { store.load(Session.self, from: Self.sessionFile) }
}
