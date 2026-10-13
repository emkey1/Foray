import AppKit
import Network
import RFFileSystem
import RFModel
import SwiftUI

/// Favorite and recent server addresses (UserDefaults).
@MainActor
enum ServerHistory {
    static let limit = 10
    static var defaults = UserDefaults.standard

    /// Posted when the favorites or recents change (the sidebar lists them under Network).
    static let changed = Notification.Name("ForayServerHistoryChanged")

    static var favorites: [String] {
        get { defaults.stringArray(forKey: "ServerFavorites") ?? [] }
        set {
            defaults.set(newValue, forKey: "ServerFavorites")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static var recents: [String] {
        get { defaults.stringArray(forKey: "RecentServers") ?? [] }
        set {
            defaults.set(Array(newValue.prefix(limit)), forKey: "RecentServers")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Servers to offer in the sidebar: favorites, then recent ones, without repeats.
    static var saved: [String] {
        var seen = Set<String>()
        return (favorites + recents).filter { seen.insert($0.lowercased()).inserted }
    }

    /// How an address reads in a list: without the scheme when it's the usual one.
    static func title(for address: String) -> String {
        var s = address
        for prefix in ["smb://", "cifs://"] where s.lowercased().hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    static func noteConnected(_ address: String) {
        recents = [address] + recents.filter { $0 != address }
    }
}

/// Mounts a server and shows it: in the front window if there is one, else a new window.
@MainActor
enum ServerConnector {
    static func connect(_ url: URL, address: String? = nil, then show: ((URL) -> Void)? = nil) async -> Error? {
        do {
            let mount = try await NetworkMounts.mount(url)
            if let address { ServerHistory.noteConnected(address) }
            if let show { show(mount) } else { WindowManager.shared.show(.folder(mount)) }
            return nil
        } catch {
            return error
        }
    }
}

@MainActor
@Observable
final class ConnectModel {
    var address = ServerHistory.recents.first ?? ""
    var favorites = ServerHistory.favorites
    var recents = ServerHistory.recents
    var connecting = false
    var error: String?
    var onDone: (() -> Void)?

    var isValid: Bool { NetworkMounts.normalize(address) != nil }

    func addFavorite() {
        guard isValid, !favorites.contains(address) else { return }
        favorites.append(address)
        ServerHistory.favorites = favorites
    }

    func removeFavorite(_ address: String) {
        favorites.removeAll { $0 == address }
        ServerHistory.favorites = favorites
    }

    func connect() {
        guard let url = NetworkMounts.normalize(address) else {
            error = "Enter a server address, like smb://server/share."
            return
        }
        connecting = true
        error = nil
        let address = address
        Task {
            let failure = await ServerConnector.connect(url, address: address)
            connecting = false
            recents = ServerHistory.recents
            if let failure { error = failure.localizedDescription } else { onDone?() }
        }
    }
}

struct ConnectView: View {
    @Bindable var model: ConnectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("smb://server/share", text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.connect() }
                Button { model.addFavorite() } label: { Image(systemName: "plus") }
                    .help("Add to Favorite Servers")
                    .disabled(!model.isValid)
            }
            Text("SMB is used unless you type another kind of address (afp://, nfs://, https:// for WebDAV).")
                .font(.callout).foregroundStyle(.secondary)
            if !model.favorites.isEmpty {
                Text("Favorite Servers").font(.headline)
                list(model.favorites, removable: true)
            }
            if !model.recents.isEmpty {
                Text("Recent Servers").font(.headline)
                list(model.recents, removable: false)
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                if model.connecting { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { model.onDone?() }.keyboardShortcut(.cancelAction)
                Button("Connect") { model.connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.isValid || model.connecting)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func list(_ items: [String], removable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items, id: \.self) { address in
                HStack {
                    Image(systemName: "server.rack").foregroundStyle(.secondary)
                    Text(address).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if removable {
                        Button { model.removeFavorite(address) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.address = address; model.connect() }
                .onTapGesture { model.address = address }
            }
        }
    }
}

/// Go › Connect to Server… (⌘K).
@MainActor
public final class ConnectToServerWindowController: NSWindowController {
    public static let shared = ConnectToServerWindowController()
    let model = ConnectModel()

    private init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260), styleMask: [.titled, .closable],
                             backing: .buffered, defer: true)
        window.title = "Connect to Server"
        super.init(window: window)
        window.contentView = NSHostingView(rootView: ConnectView(model: model))
        model.onDone = { [weak window] in window?.orderOut(nil) }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    public func show() {
        model.error = nil
        model.recents = ServerHistory.recents
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// File servers on the local network, for the sidebar's Network section: ones that announce
/// themselves with Bonjour (Macs, most NAS units), and Windows-style ones that answer NetBIOS
/// queries (`NetBIOSDiscovery`: many Samba servers, older NAS units, some PCs). Anything else is
/// reached with Connect to Server.
@MainActor
public final class NetworkBrowser {
    public static let shared = NetworkBrowser()
    private(set) var services: [String] = []
    /// Windows-style servers found, minus this Mac.
    private(set) var windowsHosts: [NetBIOSDiscovery.Host] = []
    /// The addresses and host names of the Bonjour servers, to recognize a machine found both ways.
    private(set) var bonjourAddresses = Set<String>()
    private(set) var bonjourHosts = Set<String>()
    private var scanTimer: Timer?
    /// How often to look again for Windows-style servers (they don't announce coming and going).
    static let scanInterval: TimeInterval = 90
    /// macOS is refusing Foray access to the local network (System Settings › Privacy & Security ›
    /// Local Network), so nothing can be found.
    private(set) var accessDenied = false
    private var browser: NWBrowser?
    private var observers: [UUID: @MainActor () -> Void] = [:]

    /// Started by the app at launch (asks for Local Network access the first time).
    public func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            let names = results.compactMap { r -> String? in
                if case .service(let name, _, _, _) = r.endpoint { return name }
                return nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let sorted = Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    guard sorted != self.services else { return }
                    self.services = sorted
                    for o in self.observers.values { o() }
                    self.scanForWindowsHosts()   // and look up the new list's addresses
                }
            }
        }
        b.stateUpdateHandler = { state in
            // kDNSServiceErr_PolicyDenied: the user (or a profile) turned Local Network access off.
            let denied: Bool = switch state {
            case .waiting(.dns(let code)), .failed(.dns(let code)): code == -65570
            default: false
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard denied != self.accessDenied else { return }
                    self.accessDenied = denied
                    for o in self.observers.values { o() }
                }
            }
        }
        b.start(queue: .main)
        browser = b
        scanForWindowsHosts()
        scanTimer = Timer.scheduledTimer(withTimeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanForWindowsHosts() }
        }
    }

    private var isScanning = false
    /// Asked to look again while a look was under way (the Bonjour list changed meanwhile).
    private var scanAgain = false

    private func scanForWindowsHosts() {
        guard !isScanning else {
            scanAgain = true
            return
        }
        isScanning = true
        let names = services
        Task { @MainActor in
            async let scan = NetBIOSDiscovery.scan()
            async let resolved = Task.detached(priority: .utility) {
                names.reduce(into: (hosts: Set<String>(), addresses: Set<String>())) { all, name in
                    let machine = BonjourResolver.machine(forSMBService: name)
                    if let host = machine.host { all.hosts.insert(host) }
                    all.addresses.formUnion(machine.addresses)
                }
            }.value
            let (found, bonjour) = await (scan, resolved)
            let mine = NetBIOSDiscovery.localAddresses()
            let others = found.filter { !mine.contains($0.address) }
            self.isScanning = false
            if self.scanAgain {
                self.scanAgain = false
                self.scanForWindowsHosts()
            }
            guard others != self.windowsHosts || bonjour.addresses != self.bonjourAddresses || bonjour.hosts != self.bonjourHosts else { return }
            self.windowsHosts = others
            self.bonjourAddresses = bonjour.addresses
            self.bonjourHosts = bonjour.hosts
            for o in self.observers.values { o() }
        }
    }

    /// Whether a Windows-style name is plainly the same machine as a Bonjour one. The two names
    /// come from different settings ("Anna's MacBook Pro" and "ANNAS-MACBOOK-P"), so compare the
    /// letters and digits only, allowing for NetBIOS's 15-character limit.
    static func isSameMachine(windowsName: String, bonjourName: String) -> Bool {
        func plain(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        let w = plain(windowsName), b = plain(bonjourName)
        guard !w.isEmpty, !b.isEmpty else { return false }
        return w == b || (w.count >= 8 && b.hasPrefix(w))
    }

    /// The Windows-style servers to list: those Bonjour hasn't already listed. A machine found
    /// both ways shows up with the same address, or (on two network connections at once, with a
    /// different address on each) the same host name; failing both, plainly the same display name.
    var unlistedWindowsHosts: [NetBIOSDiscovery.Host] {
        windowsHosts.filter { host in
            !bonjourAddresses.contains(host.address)
                && !(bonjourHosts.union(services)).contains { Self.isSameMachine(windowsName: host.name, bonjourName: $0) }
        }
    }

    static func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(url) }
    }

    func observe(_ body: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = body
        return id
    }

    /// Tests set services directly.
    func setServicesForTesting(_ names: [String], accessDenied: Bool = false, windowsHosts: [NetBIOSDiscovery.Host] = [],
                               bonjourAddresses: Set<String> = [], bonjourHosts: Set<String> = []) {
        services = names
        self.windowsHosts = windowsHosts
        self.bonjourAddresses = bonjourAddresses
        self.bonjourHosts = bonjourHosts
        self.accessDenied = accessDenied
        for o in observers.values { o() }
    }
}
