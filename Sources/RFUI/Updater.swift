import AppKit
import Security

/// Automatic updates from GitHub Releases (no third-party updater): check, offer, download the
/// DMG, check the app inside is Foray signed with our Developer ID and notarized, replace this
/// copy and relaunch. Test builds (Foray Dev) never update themselves.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let notes: String
    public let dmg: URL
    public let page: URL

    /// From the GitHub API's release JSON. Nil if it has no DMG.
    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }),
              let url = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return ReleaseInfo(version: version, notes: json["body"] as? String ?? "", dmg: url, page: page)
    }
}

public enum Versions {
    /// "0.10.0" > "0.9.12" > "0.9"; non-numeric parts count as 0.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

@MainActor
public final class Updater {
    public static let shared = Updater()

    static let latestURL = URL(string: "https://api.github.com/repos/emkey1/Foray/releases/latest")!
    /// Who may replace this app: Foray, signed with our Developer ID (team UYU5FM4LQ4).
    nonisolated static let requirement = #"identifier "io.github.emkey1.Foray" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "UYU5FM4LQ4""#

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var isUpdatable: Bool { Bundle.main.bundleIdentifier == "io.github.emkey1.Foray" }
    private var checking = false

    // MARK: Settings

    static var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "CheckForUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "CheckForUpdates") }
    }
    private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "LastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "LastUpdateCheck") }
    }
    private var skipped: String? {
        get { UserDefaults.standard.string(forKey: "SkippedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "SkippedVersion") }
    }

    // MARK: Checking

    /// At launch: at most once a day, quietly unless there's something new.
    public func checkInBackgroundIfDue() {
        guard isUpdatable, Self.automatic, Date().timeIntervalSince(lastCheck ?? .distantPast) > 86_400 else { return }
        Task { await check(userInitiated: false) }
    }

    /// Foray › Check for Updates…
    public func checkNow() { Task { await check(userInitiated: true) } }

    func fetchLatest() async throws -> ReleaseInfo? {
        var request = URLRequest(url: Self.latestURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ReleaseInfo.parse(data)
    }

    private func check(userInitiated: Bool) async {
        guard !checking else { return }
        guard isUpdatable else {
            if userInitiated { inform("Updates are for the released Foray", "This is a test build (\(Bundle.main.bundleIdentifier ?? "")); it doesn't update itself.") }
            return
        }
        checking = true
        defer { checking = false }
        do {
            let latest = try await fetchLatest()
            lastCheck = Date()
            guard let latest, Versions.isNewer(latest.version, than: currentVersion) else {
                if userInitiated { inform("Foray is up to date", "You have the latest version, \(currentVersion).") }
                return
            }
            if !userInitiated && skipped == latest.version { return }
            offer(latest)
        } catch {
            if userInitiated { inform("Couldn't check for updates", error.localizedDescription) }
        }
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private func offer(_ release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "Foray \(release.version) is available"
        alert.informativeText = "You have \(currentVersion). Install it now? Foray will relaunch."
        let notes = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
        notes.string = release.notes
        notes.isEditable = false
        notes.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
        scroll.documentView = notes
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: skipped = release.version
        default: break
        }
    }

    // MARK: Installing

    public struct InstallError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private func install(_ release: ReleaseInfo) {
        let target = Bundle.main.bundleURL
        let panel = ProgressPanel(title: "Updating Foray to \(release.version)…")
        panel.show()
        Task {
            do {
                try Self.checkInstallable(target)
                let (dmg, _) = try await URLSession.shared.download(from: release.dmg)
                panel.status("Checking the download…")
                try await Task.detached { try Self.installFromDMG(dmg, replacing: target) }.value
                panel.close()
                Self.relaunch(target)
            } catch {
                panel.close()
                inform("Foray couldn't update", error.localizedDescription + "\n\nYou can download it yourself from \(release.page.absoluteString).")
            }
        }
    }

    /// The running copy must be somewhere we can replace it (not inside a disk image or a
    /// read-only, quarantined "translocated" location).
    nonisolated static func checkInstallable(_ app: URL) throws {
        let path = app.path
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            throw InstallError(message: "Move Foray to your Applications folder first, then update.")
        }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw InstallError(message: "Foray's folder (\(app.deletingLastPathComponent().path)) isn't writable.")
        }
    }

    /// Mounts the DMG, verifies the app inside and replaces `target` with it.
    nonisolated static func installFromDMG(_ dmg: URL, replacing target: URL) throws {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("foray-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path]) == 0 else {
            throw InstallError(message: "The downloaded disk image couldn't be opened.")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        let app = mount.appendingPathComponent("Foray.app")
        try replace(target, with: app, verify: verify)
    }

    /// Copies `new` next to `target` (same volume, so the swap is atomic), verifies it, swaps.
    nonisolated static func replace(_ target: URL, with new: URL, verify: (URL) throws -> Void) throws {
        try verify(new)
        let staged = target.deletingLastPathComponent().appendingPathComponent(".Foray-update-\(UUID().uuidString.prefix(8)).app")
        guard run("/usr/bin/ditto", [new.path, staged.path]) == 0 else { throw InstallError(message: "Couldn't copy the new version.") }
        do {
            try verify(staged)   // what we install is exactly what we checked
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// Foray, signed with our Developer ID, and notarized by Apple.
    nonisolated static func verify(_ app: URL) throws {
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &req) == errSecSuccess
        else { throw InstallError(message: "The download isn't a valid app.") }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), req)
        guard status == errSecSuccess else {
            throw InstallError(message: "The download isn't signed by Foray's developer (\(status)), so it wasn't installed.")
        }
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) == 0 else {
            throw InstallError(message: "The download isn't notarized by Apple, so it wasn't installed.")
        }
    }

    nonisolated static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Opens the new copy once this one has quit.
    static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        FinderTakeover.isRelaunchingForUpdate = true   // no "Quit Foray?" question in the way
        NSApp.terminate(nil)
    }
}

/// A small window with a spinner while an update downloads and installs.
@MainActor
final class ProgressPanel {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
    private let label = NSTextField(labelWithString: "Downloading…")

    init(title: String) {
        panel.title = title
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let stack = NSStackView(views: [spinner, label])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = stack
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func status(_ text: String) { label.stringValue = text }
    func close() { panel.orderOut(nil) }
}
