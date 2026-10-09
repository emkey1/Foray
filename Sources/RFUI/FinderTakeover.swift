import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// The system settings "Use Foray instead of Finder" changes. Behind a protocol so tests never
/// touch the real ones.
@MainActor
protocol SystemControl: AnyObject {
    /// Finder's own desktop icons (its CreateDesktop preference).
    var finderDesktopShown: Bool { get }
    func setFinderDesktop(shown: Bool)
    /// The default app for folders.
    var folderHandler: String? { get }
    func setFolderHandler(_ bundleID: String)
    var loginItem: Bool { get }
    /// Returns false if macOS wants the user to approve it in System Settings › Login Items.
    @discardableResult func setLoginItem(_ on: Bool) -> Bool
    var finderRunning: Bool { get }
    func quitFinder()
    func launchFinder()
}

/// The real settings. Used only when the user turns the switch on or off in Settings.
@MainActor
final class RealSystemControl: SystemControl {
    static let finder = "com.apple.finder"

    private func finderPref(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, Self.finder as CFString)
    }

    private func setFinderPref(_ key: String, _ value: Any?) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, Self.finder as CFString)
        CFPreferencesAppSynchronize(Self.finder as CFString)
    }

    var finderDesktopShown: Bool { finderPref("CreateDesktop") as? Bool ?? true }

    func setFinderDesktop(shown: Bool) {
        setFinderPref("CreateDesktop", shown ? nil : false)   // no key is Finder's default: shown
        // Finder reads it at launch, so restart it if it's running.
        if finderRunning { run("/usr/bin/killall", ["Finder"]) }
    }

    var folderHandler: String? {
        NSWorkspace.shared.urlForApplication(toOpen: .folder).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    func setFolderHandler(_ bundleID: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .folder) { _ in }
    }

    var loginItem: Bool { SMAppService.mainApp.status == .enabled }

    func setLoginItem(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            return !on
        }
        return SMAppService.mainApp.status != .requiresApproval
    }

    var finderRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.finder).isEmpty }

    /// Finder only quits when its hidden Quit menu item is allowed.
    func quitFinder() {
        setFinderPref("QuitMenuItem", true)
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.finder).forEach { $0.terminate() }
    }

    func launchFinder() {
        setFinderPref("QuitMenuItem", nil)
        guard !finderRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.finder) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    private func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}

/// "Use Foray instead of Finder" (Settings › General). Off when Foray is installed and stays off
/// until the user turns it on there; nothing here runs before that. When on: Foray draws the
/// desktop and Finder's desktop icons are hidden, folders from other apps open in Foray,
/// "Show in Finder" opens Foray, and Foray opens at login; optionally Finder is quit. It records
/// what it changed, and turning it off undoes exactly that.
@MainActor
public enum FinderTakeover {
    static var system: SystemControl = RealSystemControl()
    static var defaults = UserDefaults.standard
    /// The desktop window (tests substitute these so nothing appears on screen).
    static var showDesktop: () -> Void = { DesktopWindowController.show() }
    static var hideDesktop: () -> Void = { DesktopWindowController.hide() }
    static let finderID = "com.apple.finder"
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "io.github.emkey1.Foray" }

    /// What was changed, so it can be put back.
    struct State: Codable, Equatable {
        var enabled = false
        var quitFinder = false
        var hidFinderDesktop = false
        var previousFolderHandler: String?
        var tookFolders = false
        var setFileViewer = false
        var addedLoginItem = false
    }

    static var state: State {
        get { defaults.data(forKey: "FinderTakeover").flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "FinderTakeover") }
    }

    public static var isEnabled: Bool { state.enabled }

    /// Turns it on (only from the Settings switch). Returns notes for anything the user must do,
    /// such as approving the login item.
    @discardableResult
    static func enable(quitFinder: Bool) -> [String] {
        var s = state
        if s.enabled { return setQuitFinder(quitFinder) }
        var notes: [String] = []
        s.enabled = true
        s.quitFinder = quitFinder
        showDesktop()
        if system.finderDesktopShown {
            system.setFinderDesktop(shown: false)
            s.hidFinderDesktop = true
        }
        let handler = system.folderHandler
        if handler != bundleID {
            s.previousFolderHandler = handler ?? finderID
            system.setFolderHandler(bundleID)
            s.tookFolders = true
        }
        if !FileViewerSetting.isForay {
            FileViewerSetting.set(true)
            s.setFileViewer = true
        }
        if !system.loginItem {
            if !system.setLoginItem(true) {
                notes.append("To open Foray at login, allow it in System Settings › General › Login Items.")
            }
            s.addedLoginItem = true
        }
        state = s
        if quitFinder { system.quitFinder() }
        return notes
    }

    @discardableResult
    static func setQuitFinder(_ on: Bool) -> [String] {
        var s = state
        guard s.enabled, s.quitFinder != on else { return [] }
        s.quitFinder = on
        state = s
        if on { system.quitFinder() } else { system.launchFinder() }
        return []
    }

    /// Turns it off, restoring only what it changed.
    static func disable() {
        let s = state
        guard s.enabled else { return }
        hideDesktop()
        if s.quitFinder || !system.finderRunning { system.launchFinder() }
        if s.hidFinderDesktop { system.setFinderDesktop(shown: true) }
        if s.tookFolders, system.folderHandler == bundleID { system.setFolderHandler(s.previousFolderHandler ?? finderID) }
        if s.setFileViewer { FileViewerSetting.set(false) }
        if s.addedLoginItem { system.setLoginItem(false) }
        state = State()
    }

    /// Quitting Foray while it's on: the desktop icons go too, until Foray opens again.
    public static func confirmQuit() -> Bool {
        guard !defaults.bool(forKey: "FinderTakeoverQuitWithoutAsking") else { return true }
        let alert = NSAlert()
        alert.messageText = "Quit Foray?"
        alert.informativeText = "Foray is showing your desktop icons, so they'll disappear until Foray opens again. To give the desktop back to Finder, turn off “Use Foray instead of Finder” in Foray › Settings."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let quit = alert.runModal() == .alertFirstButtonReturn
        if quit, alert.suppressionButton?.state == .on { defaults.set(true, forKey: "FinderTakeoverQuitWithoutAsking") }
        return quit
    }

    /// At launch, only if the user turned it on: show the desktop, and if macOS brought Finder's
    /// desktop (or Finder) back, keep things as the user chose.
    public static func applyAtLaunch() {
        let s = state
        guard s.enabled else { return }
        showDesktop()
        if s.hidFinderDesktop, system.finderDesktopShown { system.setFinderDesktop(shown: false) }
        if s.quitFinder, system.finderRunning { system.quitFinder() }
    }
}
