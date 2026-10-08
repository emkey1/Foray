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

    static var favorites: [String] {
        get { defaults.stringArray(forKey: "ServerFavorites") ?? [] }
        set { defaults.set(newValue, forKey: "ServerFavorites") }
    }

    static var recents: [String] {
        get { defaults.stringArray(forKey: "RecentServers") ?? [] }
        set { defaults.set(Array(newValue.prefix(limit)), forKey: "RecentServers") }
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

/// SMB servers on the local network (Bonjour), for the sidebar's Network section.
@MainActor
public final class NetworkBrowser {
    public static let shared = NetworkBrowser()
    private(set) var services: [String] = []
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
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func observe(_ body: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = body
        return id
    }

    /// Tests set services directly.
    func setServicesForTesting(_ names: [String]) {
        services = names
        for o in observers.values { o() }
    }
}
