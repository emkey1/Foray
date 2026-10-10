import Foundation
import RFOperations

// Foray's privileged helper (DESIGN.md §5.11): a launchd daemon that runs as root, inside the app
// bundle at Contents/Helpers/foray-helper. It isn't registered until the user turns on
// administrator access in Foray's Settings › Advanced (and approves it in System Settings), and
// it's removed when they turn it off.
//
// It does a short list of file operations (RFOperations/Privileged.swift) for Foray and nobody
// else, each one only with an administrator's authorization. It never runs commands.

final class Helper: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var connections = 0
    private var lastActivity = Date()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // launchd has already checked the caller's code signature against the listener's
        // requirement (set below); a connection that fails it never gets here.
        connection.exportedInterface = NSXPCInterface(with: ForayHelperXPC.self)
        connection.exportedObject = Service(owner: connection.effectiveUserIdentifier, touch: { [weak self] in self?.touch() })
        connection.invalidationHandler = { [weak self] in self?.closed() }
        lock.withLock {
            connections += 1
            lastActivity = Date()
        }
        connection.resume()
        return true
    }

    private func closed() {
        lock.withLock {
            connections -= 1
            lastActivity = Date()
        }
    }

    private func touch() { lock.withLock { lastActivity = Date() } }

    /// Nothing connected for a minute: quit. launchd starts the helper again when it's needed.
    var isIdle: Bool { lock.withLock { connections <= 0 && Date().timeIntervalSince(lastActivity) > 60 } }
}

final class Service: NSObject, ForayHelperXPC, @unchecked Sendable {
    /// The user at the other end, from the connection itself.
    private let owner: uid_t
    private let touch: @Sendable () -> Void

    init(owner: uid_t, touch: @escaping @Sendable () -> Void) {
        self.owner = owner
        self.touch = touch
    }

    func version(reply: @escaping @Sendable (String) -> Void) { reply(PrivilegedHelper.version) }

    func perform(_ operation: Data, authorization: Data, reply: @escaping @Sendable (Int32) -> Void) {
        touch()
        guard PrivilegedHelper.isAuthorized(authorization) else { return reply(EAUTH) }
        guard let request = try? JSONDecoder().decode(PrivilegedOperation.self, from: operation) else { return reply(EINVAL) }
        reply(PrivilegedExecutor.perform(request, owner: owner))
    }
}

// Who may connect: the app this helper belongs to (its identifier is ours without ".helper"),
// signed by the same team. Without a team identity of our own there's nothing to check against,
// so refuse to run at all.
guard let own = PrivilegedHelper.ownSignature(),
      let app = PrivilegedHelper.appIdentifier(forHelper: own.identifier),
      let requirement = PrivilegedHelper.requirement(identifier: app, team: own.team) else {
    FileHandle.standardError.write(Data("foray-helper: not signed with a team identity; exiting\n".utf8))
    exit(EXIT_FAILURE)
}
guard getuid() == 0 else {
    FileHandle.standardError.write(Data("foray-helper: runs only as a launchd daemon\n".utf8))
    exit(EXIT_FAILURE)
}

PrivilegedHelper.installRight()
let helper = Helper()
let listener = NSXPCListener(machServiceName: own.identifier)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = helper
listener.resume()

let idle = DispatchSource.makeTimerSource(queue: .main)
idle.schedule(deadline: .now() + 30, repeating: 30)
idle.setEventHandler { if helper.isIdle { exit(EXIT_SUCCESS) } }
idle.resume()
dispatchMain()
