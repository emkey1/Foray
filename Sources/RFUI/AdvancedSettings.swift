import AppKit
import RFOperations
import ServiceManagement

/// The privileged helper's registration with macOS. Behind a protocol so tests never register
/// anything on the machine they run on.
@MainActor
protocol HelperRegistration: AnyObject {
    /// Whether this copy of the app contains the helper at all.
    var isBundled: Bool { get }
    var state: AdministratorAccess.Status { get }
    func register() throws
    func unregister() throws
}

/// The real thing: `SMAppService` and the launchd plist in Contents/Library/LaunchDaemons.
/// Used only when the user flips the switch in Settings › Advanced.
@MainActor
final class SystemHelperRegistration: HelperRegistration {
    private var plistName: String {
        PrivilegedHelper.helperIdentifier(forApp: Bundle.main.bundleIdentifier ?? "io.github.emkey1.Foray") + ".plist"
    }
    private var service: SMAppService { SMAppService.daemon(plistName: plistName) }

    /// The helper is in the bundle, and this app is signed with a team identity: the app and the
    /// helper recognize each other by it, so an unsigned or ad hoc build can't use the helper.
    var isBundled: Bool {
        Self.isTeamSigned
            && FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(plistName)").path)
    }
    private static let isTeamSigned = PrivilegedHelper.ownSignature() != nil

    var state: AdministratorAccess.Status {
        guard isBundled else { return .unavailable }
        switch service.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

/// "Allow operations that need an administrator" (Settings › Advanced; DESIGN.md §5.11). Off when
/// Foray is installed and stays off until the user turns it on there: only then is the helper
/// registered with macOS (which also asks the user to approve it), and turning it off removes it.
/// With it on, a file operation that fails for lack of permission asks for an administrator's
/// password and carries on through the helper.
@MainActor
public enum AdministratorAccess {
    enum Status: Equatable {
        /// This build can't use the helper: it has none (run straight from `swift build`), or it
        /// isn't signed with a developer team's certificate.
        case unavailable
        case off
        /// Registered, but waiting for the user in System Settings › General › Login Items & Extensions.
        case needsApproval
        case on
    }

    static var registration: HelperRegistration = SystemHelperRegistration()

    static var status: Status { registration.state }

    /// Registered by the user (whether or not macOS has been told to allow it yet).
    static var isOn: Bool { status == .on || status == .needsApproval }

    /// Turns it on. Returns a note for the user, or nil.
    @discardableResult
    static func turnOn() -> String? {
        guard registration.isBundled else { return "This copy of Foray doesn't include the helper." }
        var note: String?
        do {
            try registration.register()
        } catch {
            // macOS reports "needs approval" as an error from register(); the state says which it is.
            if status == .off { note = "macOS wouldn't register the helper: \(error.localizedDescription)" }
        }
        if status == .needsApproval { note = approvalNote }
        apply()
        return note
    }

    static let approvalNote = "To finish, allow Foray in System Settings › General › Login Items & Extensions."

    static func turnOff() {
        try? registration.unregister()
        apply()
    }

    /// Gives the operation engine its route to the helper, or takes it away.
    public static func apply(to center: OperationCenter = .shared) {
        let helper: ElevationProvider = { title in PrivilegedHelper.session(jobTitle: title) }
        center.elevation = isOn ? helper : nil
    }

    static func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    /// Added to a "couldn't be processed" report when permission was the problem and this is off.
    static func hint(for result: OperationResult) -> String? {
        guard status == .off, result.errors.contains(where: { $0.code == EACCES }) else { return nil }
        return "To do this with an administrator's password, turn on administrator access in Settings › Advanced."
    }
}

/// The `foray` command in Terminal (Settings › Advanced): a link in /usr/local/bin to the tool
/// inside the app, so it always matches the installed version. Homebrew makes its own link.
@MainActor
enum CommandLineTool {
    enum Status: Equatable {
        /// This build has no tool (run straight from `swift build`).
        case unavailable
        case notInstalled
        case installed
        /// A `foray` link that points somewhere else (another copy of the app, or Homebrew's).
        case elsewhere(String)
        /// Something that isn't a link is in the way; Foray won't touch it.
        case blocked
    }

    enum InstallResult: Equatable {
        case done
        /// /usr/local/bin isn't writable: the Terminal command that does it.
        case needsAdministrator(command: String)
        case failed(String)
    }

    /// Where the tool is, and where the link goes (tests substitute both).
    static var tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/foray")
    static var link = URL(fileURLWithPath: "/usr/local/bin/foray")

    static var status: Status {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: tool.path) else { return .unavailable }
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            let resolved = URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
            return resolved.path == tool.standardizedFileURL.path ? .installed : .elsewhere(resolved.path)
        }
        var st = stat()
        return lstat(link.path, &st) == 0 ? .blocked : .notInstalled
    }

    /// Other places a `foray` command already is (Homebrew), so Settings can say there's nothing to do.
    static var homebrewLink: String? {
        ["/opt/homebrew/bin/foray", "/usr/local/bin/foray"].first {
            $0 != link.path && FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static func install() -> InstallResult {
        let fm = FileManager.default
        switch status {
        case .unavailable: return .failed("This copy of Foray doesn't include the command-line tool.")
        case .installed: return .done
        case .blocked: return .failed("\(link.path) already exists and isn't a link, so Foray left it alone.")
        case .notInstalled, .elsewhere: break
        }
        let dir = link.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil { try fm.removeItem(at: link) }
            try fm.createSymbolicLink(at: link, withDestinationURL: tool)
            return .done
        } catch let error as NSError where [NSFileWriteNoPermissionError, NSFileWriteUnknownError].contains(error.code)
            || (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EACCES) {
            func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            return .needsAdministrator(command: "sudo mkdir -p \(quoted(dir.path)) && sudo ln -sf \(quoted(tool.path)) \(quoted(link.path))")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Removes the link, if it's ours.
    @discardableResult
    static func uninstall() -> Bool {
        guard status == .installed else { return false }
        return (try? FileManager.default.removeItem(at: link)) != nil
    }
}
