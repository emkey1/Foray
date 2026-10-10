import AppKit
import RFFileSystem
import RFModel
import SwiftUI

/// Several selected items: how many, their total size and what kinds they are.
struct SelectionSummary: Equatable {
    var count = 0
    var folders = 0
    var bytes: Int64 = 0
    var kinds: [(name: String, count: Int)] = []

    static func == (a: SelectionSummary, b: SelectionSummary) -> Bool {
        a.count == b.count && a.folders == b.folders && a.bytes == b.bytes && a.kinds.map(\.name) == b.kinds.map(\.name)
            && a.kinds.map(\.count) == b.kinds.map(\.count)
    }

    init() {}

    init(_ items: [FileItem], folderSizes: [FileID: Int64] = [:]) {
        count = items.count
        folders = items.filter(\.isNavigableFolder).count
        bytes = items.reduce(0) { $0 + ($1.size ?? folderSizes[$1.id] ?? 0) }
        var byKind: [String: Int] = [:]
        for item in items { byKind[KindNames.name(for: item), default: 0] += 1 }
        kinds = byKind.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }
}

struct SummaryView: View {
    let summary: SelectionSummary
    let calculating: Bool

    var body: some View {
        Form {
            Section {
                Text("\(summary.count) items").font(.headline)
                LabeledContent("Size") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file))
                        if calculating { ProgressView().controlSize(.small) }
                    }
                }
                if summary.folders > 0 { LabeledContent("Folders", value: "\(summary.folders)") }
            }
            Section("Kinds") {
                ForEach(summary.kinds, id: \.name) { k in LabeledContent(k.name, value: "\(k.count)") }
            }
        }
        .formStyle(.grouped)
    }
}

/// View › Show Inspector (⌥⌘I): Get Info for whatever is selected in the front window, updating
/// as the selection changes (DESIGN.md §4.5).
@MainActor
final class InspectorPanel: NSPanel {
    static let shared = InspectorPanel()
    private weak var state: BrowserState?
    private var observed = Set<ObjectIdentifier>()
    /// What's shown (the selection, or the folder when nothing is selected); nil = refresh next time.
    private var shownKey: String?
    private var sizeTask: Task<Void, Never>?
    private var infoModel: InfoModel?

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 560),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        title = "Inspector"
        isFloatingPanel = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        setFrameAutosaveName("ForayInspector")
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(activePaneChanged(_:)), name: BrowserWindowController.activePaneChanged, object: nil)
    }

    @objc private func windowBecameKey(_ note: Notification) {
        guard let window = note.object as? NSWindow, let controller = window.windowController as? BrowserWindowController else { return }
        attach(controller.browser.state)
    }

    /// Dual-pane mode: follow the pane that has the focus.
    @objc private func activePaneChanged(_ note: Notification) {
        guard let controller = note.object as? BrowserWindowController, controller.window?.isMainWindow == true else { return }
        attach(controller.browser.state)
    }

    func toggle(for state: BrowserState) {
        if isVisible {
            orderOut(nil)
        } else {
            attach(state)
            if frame.origin == .zero { center() }
            orderFront(nil)
        }
    }

    func attach(_ state: BrowserState) {
        self.state = state
        if observed.insert(ObjectIdentifier(state)).inserted {
            state.observe { [weak self, weak state] change in
                guard let self, let state, self.state === state else { return }
                switch change {
                case .selection, .location, .snapshot: self.refresh()
                default: break
                }
            }
        }
        shownKey = nil
        refresh()
    }

    func refresh() {
        guard let state else { return }
        let items = state.selectedItems
        let key = items.isEmpty ? "folder:\(state.location)" : items.map(\.id.description).joined(separator: ",")
        guard key != shownKey else { return }
        shownKey = key
        sizeTask?.cancel()
        infoModel?.cancel()
        infoModel = nil
        switch items.count {
        case 0:
            guard let url = state.location.folderURL else {
                contentView = NSHostingView(rootView: Text("Nothing selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity))
                return
            }
            Task {
                guard let item = await Task.detached(operation: { DirectoryLoader.shared.stat(url) }).value,
                      self.state === state, state.selectedItems.isEmpty else { return }
                self.show(item)
            }
        case 1:
            show(items[0])
        default:
            showSummary(items)
        }
    }

    private func show(_ item: FileItem) {
        let model = InfoModel(item: item)
        infoModel = model
        contentView = NSHostingView(rootView: InfoView(model: model))
    }

    /// Several items: summary first, then folder totals as they arrive.
    private func showSummary(_ items: [FileItem]) {
        let folders = items.filter(\.isNavigableFolder)
        let host = NSHostingView(rootView: SummaryView(summary: SelectionSummary(items), calculating: !folders.isEmpty))
        contentView = host
        guard !folders.isEmpty else { return }
        sizeTask = Task { [weak self] in
            var sizes: [FileID: Int64] = [:]
            for folder in folders {
                if let size = await FolderSizes.shared.size(of: folder) { sizes[folder.id] = size }
                guard !Task.isCancelled, let self, self.contentView === host else { return }
                host.rootView = SummaryView(summary: SelectionSummary(items, folderSizes: sizes), calculating: sizes.count < folders.count)
            }
        }
    }
}

extension BrowserViewController {
    @objc func showInspector(_ sender: Any?) { InspectorPanel.shared.toggle(for: state) }
}
