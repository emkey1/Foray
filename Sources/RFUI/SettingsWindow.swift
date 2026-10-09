import AppKit
import RFFileSystem
import RFModel
import SwiftUI

/// App preferences (UserDefaults). View settings live in AppModel; these are behaviors.
@MainActor
enum AppSettings {
    private static let defaults = UserDefaults.standard

    enum SearchScopeDefault: String, CaseIterable {
        case currentFolder, thisMac, previous
        var title: String {
            switch self {
            case .currentFolder: "The current folder"
            case .thisMac: "This Mac"
            case .previous: "Whatever I used last"
            }
        }
    }

    /// Where ⌘N opens. Nil = Home.
    static var newWindowFolder: URL? {
        get { defaults.string(forKey: "NewWindowFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: "NewWindowFolder") }
    }

    /// ⌘-double-click and Open in New Tab open tabs (true) or windows (false).
    static var openFoldersInTabs: Bool {
        get { defaults.object(forKey: "OpenFoldersInTabs") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "OpenFoldersInTabs") }
    }

    /// Return renames (Finder) or opens (DESIGN.md I11).
    static var returnOpens: Bool {
        get { defaults.bool(forKey: "ReturnOpens") }
        set { defaults.set(newValue, forKey: "ReturnOpens") }
    }

    static var searchScopeDefault: SearchScopeDefault {
        get { defaults.string(forKey: "SearchScopeDefault").flatMap(SearchScopeDefault.init) ?? .currentFolder }
        set { defaults.set(newValue.rawValue, forKey: "SearchScopeDefault") }
    }

    static var lastSearchWasThisMac: Bool {
        get { defaults.bool(forKey: "LastSearchWasThisMac") }
        set { defaults.set(newValue, forKey: "LastSearchWasThisMac") }
    }

    static var defaultMatch: MatchMode {
        get { defaults.string(forKey: "DefaultMatch").flatMap(MatchMode.init) ?? .names }
        set { defaults.set(newValue.rawValue, forKey: "DefaultMatch") }
    }

    static var newWindowLocation: Location {
        .folder(newWindowFolder ?? FileManager.default.homeDirectoryForCurrentUser)
    }
}

/// Full Disk Access can't be queried directly; probe places only it unlocks (DESIGN.md §5.11).
enum FullDiskAccess {
    static var isGranted: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in ["Library/Safari", ".Trash", "Library/Mail"] {
            if (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(path).path)) != nil { return true }
        }
        return false
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
@Observable
final class SettingsPaneModel {
    var newWindowFolder: URL? = AppSettings.newWindowFolder { didSet { AppSettings.newWindowFolder = newWindowFolder } }
    var openFoldersInTabs = AppSettings.openFoldersInTabs { didSet { AppSettings.openFoldersInTabs = openFoldersInTabs } }
    var returnOpens = AppSettings.returnOpens { didSet { AppSettings.returnOpens = returnOpens } }
    var searchScope = AppSettings.searchScopeDefault { didSet { AppSettings.searchScopeDefault = searchScope } }
    var defaultMatch = AppSettings.defaultMatch { didSet { AppSettings.defaultMatch = defaultMatch } }
    var followFolders = BrowserState.searchFollowsFolderChanges { didSet { BrowserState.searchFollowsFolderChanges = followFolders } }
    var perFolderSettings = AppModel.shared.settings.model == .perFolder {
        didSet { AppModel.shared.setSettingsModel(perFolderSettings ? .perFolder : .sameEverywhere) }
    }
    var fullDiskAccess = FullDiskAccess.isGranted
    var fileViewer = FileViewerSetting.isForay { didSet { if fileViewer != oldValue { FileViewerSetting.set(fileViewer) } } }
    var fileViewerName = FileViewerSetting.currentViewerName
    var checkForUpdates = Updater.automatic { didSet { Updater.automatic = checkForUpdates } }

    func chooseNewWindowFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK { newWindowFolder = panel.url }
    }

    func refreshAccess() {
        fullDiskAccess = FullDiskAccess.isGranted
        fileViewer = FileViewerSetting.isForay
        fileViewerName = FileViewerSetting.currentViewerName
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsPaneModel

    var body: some View {
        TabView {
            Form {
                LabeledContent("New windows open") {
                    HStack {
                        Text(model.newWindowFolder.map { FileManager.default.displayName(atPath: $0.path) } ?? "Home")
                        Button("Choose…") { model.chooseNewWindowFolder() }
                        if model.newWindowFolder != nil { Button("Home") { model.newWindowFolder = nil } }
                    }
                }
                Toggle("Open folders in tabs instead of new windows", isOn: $model.openFoldersInTabs)
                Picker("Return key", selection: $model.returnOpens) {
                    Text("Renames the selected item (like Finder)").tag(false)
                    Text("Opens the selected item").tag(true)
                }
                Toggle("Check for updates automatically", isOn: $model.checkForUpdates)
                    .help("Once a day, Foray asks GitHub whether there's a newer release. It never installs without asking.")
                Toggle("Use Foray for “Show in Finder” in other apps", isOn: $model.fileViewer)
                Text(model.fileViewer
                     ? "Other apps reveal files in Foray. This is a system-wide setting; turn it off to go back to Finder."
                     : "Other apps reveal files in \(model.fileViewerName). Turning this on changes a system-wide setting; Finder stays installed and you can switch back anytime.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Picker("View settings", selection: $model.perFolderSettings) {
                    Text("The same in every folder").tag(false)
                    Text("Remembered for each folder").tag(true)
                }
                .pickerStyle(.radioGroup)
                Text("Either way, View › Remember Settings for This Folder gives a folder its own settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Views", systemImage: "square.grid.2x2") }

            Form {
                Picker("Search", selection: $model.searchScope) {
                    ForEach(AppSettings.SearchScopeDefault.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Match", selection: $model.defaultMatch) {
                    Text("Names").tag(MatchMode.names)
                    Text("Names & Contents").tag(MatchMode.namesAndContents)
                }
                Toggle("Keep searching when I go to another folder", isOn: $model.followFolders)
            }
            .formStyle(.grouped)
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            Form {
                LabeledContent("Full Disk Access") {
                    Text(model.fullDiskAccess ? "Granted" : "Not granted").foregroundStyle(model.fullDiskAccess ? .green : .orange)
                }
                Text("""
                macOS asks before any app reads Desktop, Documents, Downloads, external drives and network volumes. \
                Some places (the Trash, Mail, Messages and Safari data, other users' folders) need Full Disk Access.
                """).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open Privacy Settings") { FullDiskAccess.openSystemSettings() }
                    Button("Check Again") { model.refreshAccess() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 380)
    }
}

@MainActor
public final class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController()
    private let model = SettingsPaneModel()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.title = "Foray Settings"
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    public func show() {
        model.refreshAccess()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// First launch: what macOS will ask, and why Full Disk Access helps (DESIGN.md §5.11).
@MainActor
public enum Onboarding {
    public static func showIfNeeded() {
        let key = "OnboardingShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard !FullDiskAccess.isGranted else { return }
        let alert = NSAlert()
        alert.messageText = "Welcome to Foray"
        alert.informativeText = """
        macOS will ask before Foray can see your Desktop, Documents, Downloads, external drives and \
        network volumes. Allow these when asked.

        A few places (the Trash, Mail, Messages and Safari data, other users' folders) need Full Disk Access, \
        which you can turn on in System Settings › Privacy & Security › Full Disk Access. Foray works without it.

        The Guide (Help › Foray Guide, or ⌘?) explains everything else.
        """
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { FullDiskAccess.openSystemSettings() }
    }
}

/// Whether other apps' "Show in Finder" opens Foray: the system-wide `NSFileViewer` preference
/// (DESIGN.md §5.12, S8). Changed only when the user flips the switch in Settings; turning it off
/// removes the preference, so Finder is back.
@MainActor
public enum FileViewerSetting {
    static let key = "NSFileViewer"
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "io.github.emkey1.Foray" }

    /// The global preference. Tests substitute these so they never touch the real one.
    static var read: () -> String? = {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }
    static var write: (String?) -> Void = { value in
        CFPreferencesSetValue(key as CFString, value as CFString?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    public static var isForay: Bool { read() == bundleID }

    /// Who handles "Show in Finder" now, for the Settings note ("Finder" when unset).
    static var currentViewerName: String {
        guard let id = read(), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return "Finder" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    public static func set(_ on: Bool) {
        if on { write(bundleID) } else if isForay { write(nil) }   // don't remove another app's setting
    }
}
