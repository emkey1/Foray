import Foundation
import Security

// The connection between Foray and its privileged helper (DESIGN.md §5.11). Both sides use this
// file: the app through `PrivilegedHelper.session`, the helper (Sources/foray-helper) through the
// checks below.
//
// Three things must hold before the helper does anything:
//   1. The caller is Foray, signed by the same team as the helper (launchd enforces the
//      requirement on every connection).
//   2. The request carries an authorization holding `PrivilegedHelper.right`, which macOS grants
//      only after an administrator authenticates.
//   3. The request decodes to a `PrivilegedOperation` on acceptable paths.

/// What the helper answers over XPC.
@objc public protocol ForayHelperXPC {
    func version(reply: @escaping @Sendable (String) -> Void)
    /// `operation` is a JSON `PrivilegedOperation`; `authorization` an AuthorizationExternalForm.
    /// Replies 0 or an errno (EAUTH when the authorization doesn't hold the right).
    func perform(_ operation: Data, authorization: Data, reply: @escaping @Sendable (Int32) -> Void)
}

public enum PrivilegedHelper {
    /// The helper's own version, so the app can tell an old one is still running after an update.
    public static let version = "1"

    /// The authorization right every operation needs. Its rule (set by the helper when it starts)
    /// is "authenticate as an administrator"; the approval isn't shared with anything else and ends
    /// with the job (or after half an hour, when a long job asks again).
    public static let right = "io.github.emkey1.Foray.admin-file-operations"

    /// The helper's launchd label, Mach service and signing identifier: the app's identifier plus
    /// ".helper" (so the test build, Foray Dev, has its own).
    public static func helperIdentifier(forApp identifier: String) -> String { identifier + ".helper" }

    public static func appIdentifier(forHelper identifier: String) -> String? {
        identifier.hasSuffix(".helper") ? String(identifier.dropLast(".helper".count)) : nil
    }

    /// A code requirement: this identifier, signed with one of this team's Apple-issued certificates.
    public static func requirement(identifier: String, team: String) -> String? {
        // Both go into a requirement string, so they must be plain identifiers.
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !identifier.isEmpty, !team.isEmpty, (identifier + team).unicodeScalars.allSatisfy(plain.contains) else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// This process's signing identifier and team. No team (ad hoc or unsigned) means the other
    /// side can't be checked, so neither side will talk.
    public static func ownSignature() -> (identifier: String, team: String)? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let identifier = dict[kSecCodeInfoIdentifier as String] as? String,
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return (identifier, team)
    }

    // MARK: Authorization

    /// Helper side, at startup (as root): makes sure the right exists with the intended rule.
    public static func installRight() {
        var auth: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let auth else { return }
        defer { AuthorizationFree(auth, []) }
        let rule: [String: Any] = [
            "class": "user", "group": "admin", "authenticate-user": true, "allow-root": false,
            "shared": false, "timeout": 1800,
            "comment": "Foray: file operations that need an administrator",
        ]
        _ = AuthorizationRightSet(auth, right, rule as CFDictionary, "Foray wants to make changes that need an administrator." as CFString, nil, nil)
    }

    /// Helper side: does this authorization hold the right? Never shows anything.
    public static func isAuthorized(_ externalForm: Data) -> Bool {
        guard externalForm.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { $0.copyBytes(from: externalForm) }
        var auth: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &auth) == errAuthorizationSuccess, let auth else { return false }
        defer { AuthorizationFree(auth, []) }
        return copyRight(auth, flags: [.extendRights], prompt: nil) == errAuthorizationSuccess
    }

    static func copyRight(_ auth: AuthorizationRef, flags: AuthorizationFlags, prompt: String?) -> OSStatus {
        right.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                guard let prompt else { return AuthorizationCopyRights(auth, &rights, nil, flags, nil) }
                return prompt.withCString { text in
                    kAuthorizationEnvironmentPrompt.withCString { key in
                        var promptItem = AuthorizationItem(name: key, valueLength: strlen(text), value: UnsafeMutableRawPointer(mutating: text), flags: 0)
                        return withUnsafeMutablePointer(to: &promptItem) { promptPointer in
                            var environment = AuthorizationEnvironment(count: 1, items: promptPointer)
                            return AuthorizationCopyRights(auth, &rights, &environment, flags, nil)
                        }
                    }
                }
            }
        }
    }

    // MARK: App side

    /// An `ElevationProvider`: asks an administrator to authenticate for this job (the standard
    /// macOS dialog) and connects to the helper. Nil if they cancel or the helper can't be reached.
    /// Blocks while the dialog is up, so never call it on the main thread.
    public static func session(jobTitle: String) -> PrivilegedFileOps? {
        guard let own = ownSignature(),
              let helperRequirement = requirement(identifier: helperIdentifier(forApp: own.identifier), team: own.team) else { return nil }
        // Reach the helper first: if it isn't there (not approved yet in System Settings, say),
        // don't ask for a password that couldn't be used.
        let connection = NSXPCConnection(machServiceName: helperIdentifier(forApp: own.identifier), options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ForayHelperXPC.self)
        connection.setCodeSigningRequirement(helperRequirement)
        connection.resume()
        nonisolated(unsafe) var answered = false
        (connection.synchronousRemoteObjectProxyWithErrorHandler { _ in } as? ForayHelperXPC)?.version { _ in answered = true }
        guard answered else {
            connection.invalidate()
            return nil
        }
        var auth: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let auth else {
            connection.invalidate()
            return nil
        }
        let prompt = "Foray needs an administrator to finish “\(jobTitle)”."
        var form = AuthorizationExternalForm()
        guard copyRight(auth, flags: [.interactionAllowed, .extendRights], prompt: prompt) == errAuthorizationSuccess,
              AuthorizationMakeExternalForm(auth, &form) == errAuthorizationSuccess else {
            AuthorizationFree(auth, [.destroyRights])
            connection.invalidate()
            return nil
        }
        return HelperSession(connection: connection, authorization: auth, form: withUnsafeBytes(of: &form) { Data($0) }, prompt: prompt)
    }
}

/// One job's line to the helper. The authorization (and the administrator's approval with it)
/// ends when the job does.
final class HelperSession: PrivilegedFileOps, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let authorization: AuthorizationRef
    private let form: Data

    private let prompt: String

    init(connection: NSXPCConnection, authorization: AuthorizationRef, form: Data, prompt: String) {
        self.connection = connection
        self.authorization = authorization
        self.form = form
        self.prompt = prompt
    }

    deinit {
        connection.invalidate()
        AuthorizationFree(authorization, [.destroyRights])
    }

    func perform(_ operation: PrivilegedOperation) -> Int32 {
        let rc = send(operation)
        // The approval ran out in the middle of a long job: ask again, once.
        guard rc == EAUTH, PrivilegedHelper.copyRight(authorization, flags: [.interactionAllowed, .extendRights], prompt: prompt) == errAuthorizationSuccess else { return rc }
        return send(operation)
    }

    private func send(_ operation: PrivilegedOperation) -> Int32 {
        guard let request = try? JSONEncoder().encode(operation) else { return EINVAL }
        // Synchronous: the engine calls this from a job's own I/O queue and waits for the answer.
        nonisolated(unsafe) var result: Int32 = EIO
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { _ in result = ECONNREFUSED }
        guard let helper = proxy as? ForayHelperXPC else { return EIO }
        helper.perform(request, authorization: form) { result = $0 }
        return result
    }
}
