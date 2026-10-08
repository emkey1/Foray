import AppKit
import RFModel
import SwiftUI

/// The View Options panel (⌘J, DESIGN.md §4.2): edits the front window's settings, following
/// whichever browser window is key.
@MainActor
@Observable
final class ViewOptionsModel {
    private(set) weak var state: BrowserState?
    private(set) var settings = ViewSettings()
    private(set) var title = ""
    private(set) var isPinned = false
    private(set) var canPin = false

    /// Tabs already observed (observers aren't removable, so observe each tab once).
    private var observed = Set<ObjectIdentifier>()

    func attach(_ state: BrowserState?) {
        self.state = state
        guard let state, observed.insert(ObjectIdentifier(state)).inserted else { return refresh() }
        state.observe { [weak self, weak state] change in
            guard let self, let state, self.state === state else { return }
            if case .settings = change { self.refresh() }
            if case .details = change { self.refresh() }
            if case .location = change { self.refresh() }
        }
        refresh()
    }

    func refresh() {
        guard let state else { return }
        settings = state.settings
        title = state.details.displayName
        isPinned = state.isPinned
        canPin = state.details.folderKey != nil
    }

    func arrangement<T>(_ keyPath: WritableKeyPath<Arrangement, T>) -> Binding<T> {
        Binding(get: { self.settings.arrangement[keyPath: keyPath] }, set: { value in
            self.state?.updateArrangement { $0[keyPath: keyPath] = value }
            self.refresh()
        })
    }

    func presentation<T>(_ keyPath: WritableKeyPath<Presentation, T>) -> Binding<T> {
        Binding(get: { self.settings.presentation[keyPath: keyPath] }, set: { value in
            self.state?.updatePresentation { $0[keyPath: keyPath] = value }
            self.refresh()
        })
    }

    var sortKey: Binding<SortKey> {
        Binding(get: { self.settings.arrangement.primary.key }, set: { key in
            self.state?.updateArrangement { a in
                if a.primary.key != key { a.setPrimary(key) }
            }
            self.refresh()
        })
    }

    var ascending: Binding<Bool> {
        Binding(get: { self.settings.arrangement.primary.ascending }, set: { value in
            self.state?.updateArrangement { a in
                if a.sort.isEmpty { a.sort = [SortDescriptor(.name)] }
                a.sort[0].ascending = value
            }
            self.refresh()
        })
    }

    func columnVisible(_ column: ListColumn) -> Binding<Bool> {
        Binding(get: { self.settings.presentation.list.columns.contains { $0.column == column } }, set: { on in
            self.state?.updatePresentation { p in
                if on, !p.list.columns.contains(where: { $0.column == column }) {
                    p.list.columns.append(ListColumnSpec(column))
                } else if !on {
                    p.list.columns.removeAll { $0.column == column }
                }
            }
            self.refresh()
        })
    }

    var pinned: Binding<Bool> {
        Binding(get: { self.isPinned }, set: { _ in
            self.state?.togglePin()
            self.refresh()
        })
    }

    /// This folder's own settings become the default for all folders.
    func useAsDefaults() {
        guard let state else { return }
        AppModel.shared.setClassDefault(state.settings, cls: state.location.settingsClass)
        refresh()
    }
}

struct ViewOptionsView: View {
    @Bindable var model: ViewOptionsModel

    private let sortKeys: [SortKey] = [.name, .kind, .dateModified, .dateCreated, .dateAdded, .size, .fileExtension]

    var body: some View {
        Form {
            Section {
                Toggle("Remember settings for this folder", isOn: model.pinned).disabled(!model.canPin)
                if model.isPinned {
                    Button("Use as Defaults") { model.useAsDefaults() }
                        .help("Make these settings the default for all folders")
                }
            } header: {
                Text(model.title).font(.headline)
            }
            Section("View") {
                Picker("View as", selection: model.presentation(\.mode)) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Arrangement") {
                Picker("Sort by", selection: model.sortKey) {
                    ForEach(sortKeys, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Ascending", isOn: model.ascending)
                Picker("Group by", selection: model.arrangement(\.groupBy)) {
                    Text("None").tag(GroupKey?.none)
                    ForEach(GroupKey.allCases, id: \.self) { Text($0.title).tag(GroupKey?.some($0)) }
                }
                Toggle("Keep folders on top", isOn: model.arrangement(\.foldersFirst))
                Toggle("Show hidden files", isOn: model.arrangement(\.showHidden))
            }
            switch model.settings.presentation.mode {
            case .icon:
                Section("Icons") {
                    LabeledContent("Icon size") {
                        Slider(value: model.presentation(\.icon.iconSize), in: 16...256, step: 8)
                    }
                    LabeledContent("Grid spacing") {
                        Slider(value: model.presentation(\.icon.gridSpacing), in: 4...60, step: 2)
                    }
                    Toggle("Show icon previews", isOn: model.presentation(\.icon.showPreviews))
                }
            case .list:
                Section("Show columns") {
                    ForEach(ListColumn.allCases.filter { $0 != .name }, id: \.self) { column in
                        Toggle(column.title, isOn: model.columnVisible(column))
                    }
                    Toggle("Use relative dates", isOn: model.presentation(\.list.relativeDates))
                }
            case .column:
                Section("Columns") {
                    LabeledContent("Column width") {
                        Slider(value: model.presentation(\.column.columnWidth), in: 160...420, step: 10)
                    }
                    Toggle("Show preview column", isOn: model.presentation(\.column.showPreviewColumn))
                }
            case .gallery:
                Section("Gallery") {
                    LabeledContent("Thumbnail size") {
                        Slider(value: model.presentation(\.gallery.thumbnailSize), in: 32...160, step: 8)
                    }
                    Toggle("Show info", isOn: model.presentation(\.gallery.showMetadata))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }
}

/// The floating panel. ⌘J shows or hides it.
@MainActor
final class ViewOptionsPanel: NSPanel {
    static let shared = ViewOptionsPanel()
    let model = ViewOptionsModel()

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 520),
                   styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: true)
        title = "View Options"
        isFloatingPanel = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        contentView = NSHostingView(rootView: ViewOptionsView(model: model))
        setFrameAutosaveName("RealFinderViewOptions")
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    /// Follow the front browser window.
    @objc private func windowBecameKey(_ note: Notification) {
        guard let window = note.object as? NSWindow, let controller = window.windowController as? BrowserWindowController else { return }
        model.attach(controller.browser.state)
    }

    func toggle(for state: BrowserState) {
        if isVisible {
            orderOut(nil)
        } else {
            model.attach(state)
            if frame.origin == .zero { center() }
            orderFront(nil)
        }
    }
}

extension BrowserViewController {
    @objc func showViewOptions(_ sender: Any?) { ViewOptionsPanel.shared.toggle(for: state) }
}
