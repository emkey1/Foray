import AppKit
import CoreServices
import QuickLookThumbnailing
import RFFileSystem
import RFModel
import RFOperations
import SwiftUI

/// Everything Get Info shows, gathered off the main thread (DESIGN.md §4.5).
struct ItemInfo: Sendable {
    var url: URL
    var name: String
    var kind: String
    var isFolder: Bool
    var size: Int64?
    var allocated: Int64?
    var created: Date?
    var modified: Date?
    var added: Date?
    var lastOpened: Date?
    var owner = ""
    var group = ""
    var permissions = ""
    var mode: UInt16 = 0
    var ownedByMe = false
    var locked = false
    var extensionHidden = false
    var tags: [Tag] = []
    var comment = ""
    var more: [(String, String)] = []
    var defaultApp: String?

    static func load(_ item: FileItem) -> ItemInfo {
        var info = ItemInfo(url: item.url, name: item.name, kind: KindNames.name(for: item), isFolder: item.isNavigableFolder,
                            size: item.isNavigableFolder ? nil : item.size, allocated: item.allocatedSize,
                            created: item.created, modified: item.modified, added: item.added)
        var st = stat()
        if lstat(item.url.path, &st) == 0 {
            info.owner = getpwuid(st.st_uid).map { String(cString: $0.pointee.pw_name) } ?? "\(st.st_uid)"
            info.group = getgrgid(st.st_gid).map { String(cString: $0.pointee.gr_name) } ?? "\(st.st_gid)"
            info.permissions = Self.modeString(st.st_mode)
            info.mode = UInt16(st.st_mode & 0o777)
            info.ownedByMe = st.st_uid == getuid()
            info.locked = st.st_flags & UInt32(UF_IMMUTABLE) != 0
        }
        info.extensionHidden = (try? item.url.resourceValues(forKeys: [.hasHiddenExtensionKey]))?.hasHiddenExtension ?? false
        info.tags = Tags.read(at: item.url)
        info.comment = Comments.read(item.url)
        if let md = MDItemCreateWithURL(nil, item.url as CFURL) {
            func value(_ key: CFString) -> Any? { MDItemCopyAttribute(md, key) }
            info.lastOpened = value(kMDItemLastUsedDate) as? Date
            if let w = value(kMDItemPixelWidth) as? Int, let h = value(kMDItemPixelHeight) as? Int {
                info.more.append(("Dimensions", "\(w) × \(h)"))
            }
            if let d = value(kMDItemDurationSeconds) as? Double {
                let f = DateComponentsFormatter()
                f.allowedUnits = d >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
                f.zeroFormattingBehavior = .pad
                info.more.append(("Duration", f.string(from: d) ?? "\(Int(d)) s"))
            }
            if let pages = value(kMDItemNumberOfPages) as? Int { info.more.append(("Pages", "\(pages)")) }
            if let codecs = value(kMDItemCodecs) as? [String], !codecs.isEmpty { info.more.append(("Codecs", codecs.joined(separator: ", "))) }
            if let authors = value(kMDItemAuthors) as? [String], !authors.isEmpty { info.more.append(("Authors", authors.joined(separator: ", "))) }
            if let version = value(kMDItemVersion) as? String { info.more.append(("Version", version)) }
            if let froms = value(kMDItemWhereFroms) as? [String], !froms.isEmpty { info.more.append(("Where from", froms.joined(separator: "\n"))) }
        }
        return info
    }

    static func modeString(_ mode: mode_t) -> String {
        let type: String = switch mode & S_IFMT {
        case S_IFDIR: "d"
        case S_IFLNK: "l"
        default: "-"
        }
        let bits: [(mode_t, String)] = [(S_IRUSR, "r"), (S_IWUSR, "w"), (S_IXUSR, "x"), (S_IRGRP, "r"), (S_IWGRP, "w"),
                                        (S_IXGRP, "x"), (S_IROTH, "r"), (S_IWOTH, "w"), (S_IXOTH, "x")]
        return type + bits.map { mode & $0.0 != 0 ? $0.1 : "-" }.joined() + String(format: " (%o)", mode & 0o7777)
    }

}

/// Live state behind one Get Info window.
@MainActor
@Observable
final class InfoModel {
    var info: ItemInfo?
    var thumbnail: NSImage?
    var folderSize: (logical: Int64, allocated: Int64, items: Int)?
    var computingSize = false
    var editedName = ""
    var editedComment = ""
    let item: FileItem
    private var sizeTask: Task<Void, Never>?

    init(item: FileItem) {
        self.item = item
        editedName = item.name
        thumbnail = IconProvider.shared.icon(for: item)
        reload()
    }

    func reload() {
        let item = self.item
        Task.detached(priority: .userInitiated) {
            let info = ItemInfo.load(item)
            let app = NSWorkspace.shared.urlForApplication(toOpen: item.url).map { FileManager.default.displayName(atPath: $0.path) }
            await MainActor.run {
                var i = info
                i.defaultApp = item.isNavigableFolder ? nil : app
                self.info = i
                self.editedComment = i.comment
                if item.isNavigableFolder && self.folderSize == nil { self.computeFolderSize() }
            }
        }
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 128, height: 128), scale: 2,
                                                   representationTypes: [.icon, .thumbnail])
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage
            Task { @MainActor in if let image { self.thumbnail = image } }
        }
    }

    /// Folder sizes are totaled in the background (everything inside, hidden items and package contents too).
    func computeFolderSize() {
        computingSize = true
        let url = item.url
        sizeTask = Task {
            var logical: Int64 = 0, allocated: Int64 = 0, count = 0
            for await event in TreeWalker.walk(url, options: .init(includeHidden: true, includePackageContents: true)) {
                if Task.isCancelled { break }
                if case .items(let items) = event {
                    for i in items where !i.flags.contains(.directory) {
                        logical += i.size ?? 0
                        allocated += i.allocatedSize ?? 0
                    }
                    count += items.count
                    folderSize = (logical, allocated, count)
                }
            }
            folderSize = (logical, allocated, count)
            computingSize = false
        }
    }

    func cancel() { sizeTask?.cancel() }

    /// Locked, Hide extension, permissions and comments go through the operations engine, so
    /// they can be undone; the window refreshes when the change lands.
    func set(_ attributes: ItemAttributes) {
        FileOperationsUI.shared.submit(.setAttributes([.init(url: item.url, attributes: attributes)]), from: nil) { [weak self] _ in
            self?.reload()
        }
    }

    func commitComment() {
        guard let info, editedComment != info.comment else { return }
        set(ItemAttributes(comment: editedComment))
    }

    /// Owner/group/everyone access as Finder shows it: 0 no access, 1 read only, 2 write only, 3 read & write.
    func access(_ who: Int) -> Int {
        let bits = Int(info?.mode ?? 0) >> (6 - who * 3)
        return (bits & 4 != 0 ? 1 : 0) + (bits & 2 != 0 ? 2 : 0)
    }

    func setAccess(_ who: Int, _ level: Int) {
        guard let info else { return }
        let shift = UInt16(6 - who * 3)
        var mode = info.mode & ~(UInt16(0o6) << shift)
        if level & 1 != 0 { mode |= 4 << shift }
        if level & 2 != 0 { mode |= 2 << shift }
        guard mode != info.mode else { return }
        set(ItemAttributes(permissions: mode))
    }

    func commitName() {
        let name = editedName.trimmingCharacters(in: .whitespaces)
        guard name != item.name, FileNaming.problem(with: name) == nil else {
            editedName = item.name
            return
        }
        FileOperationsUI.shared.submit(.rename(item.url, to: name), from: nil)
    }
}

struct InfoView: View {
    @Bindable var model: InfoModel

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).textSelection(.enabled).multilineTextAlignment(.trailing) }
    }

    private func date(_ d: Date?) -> String {
        d.map { $0.formatted(date: .long, time: .shortened) } ?? "--"
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    if let thumb = model.thumbnail {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.item.displayName).font(.headline).lineLimit(2)
                        Text("\(model.info?.kind ?? "") — \(sizeSummary)").foregroundStyle(.secondary).font(.callout)
                        Text("Modified \(date(model.item.modified))").foregroundStyle(.secondary).font(.callout)
                    }
                }
            }
            Section("General") {
                row("Kind", model.info?.kind ?? "")
                LabeledContent("Size") {
                    HStack {
                        Text(sizeDetail).multilineTextAlignment(.trailing)
                        if model.computingSize { ProgressView().controlSize(.small) }
                    }
                }
                row("Where", (model.item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                row("Created", date(model.info?.created))
                row("Modified", date(model.info?.modified))
                if let added = model.info?.added { row("Added", date(added)) }
                if let opened = model.info?.lastOpened { row("Last opened", date(opened)) }
                Toggle("Locked", isOn: Binding(get: { model.info?.locked ?? false }, set: { model.set(ItemAttributes(locked: $0)) }))
                    .disabled(model.info == nil || model.info?.ownedByMe == false)
            }
            if let more = model.info?.more, !more.isEmpty {
                Section("More Info") {
                    ForEach(Array(more.enumerated()), id: \.offset) { _, pair in row(pair.0, pair.1) }
                }
            }
            Section("Name & Extension") {
                TextField("Name", text: $model.editedName).onSubmit { model.commitName() }
                    .disabled(model.info?.locked == true)
                if !model.item.pathExtension.isEmpty {
                    Toggle("Hide extension", isOn: Binding(get: { model.info?.extensionHidden ?? false },
                                                           set: { model.set(ItemAttributes(extensionHidden: $0)) }))
                }
            }
            Section("Tags") {
                if let tags = model.info?.tags, !tags.isEmpty {
                    HStack {
                        ForEach(tags, id: \.name) { tag in
                            HStack(spacing: 4) {
                                Circle().fill(Color(nsColor: tag.color.nsColor ?? .tertiaryLabelColor)).frame(width: 9, height: 9)
                                Text(tag.name)
                            }
                        }
                    }
                } else {
                    Text("No tags").foregroundStyle(.secondary)
                }
            }
            Section("Comments") {
                TextField("Add a comment", text: $model.editedComment, axis: .vertical)
                    .lineLimit(2...6)
                    .onSubmit { model.commitComment() }
                if model.editedComment != (model.info?.comment ?? "") {
                    HStack {
                        Spacer()
                        Button("Revert") { model.editedComment = model.info?.comment ?? "" }
                        Button("Save Comment") { model.commitComment() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
            if let app = model.info?.defaultApp {
                Section("Opens With") { Text(app) }
            }
            Section("Sharing & Permissions") {
                let labels = [model.info?.owner ?? "Owner", model.info?.group ?? "Group", "everyone"]
                ForEach(0..<3, id: \.self) { who in
                    Picker(who == 0 && model.info?.ownedByMe == true ? "\(labels[0]) (Me)" : labels[who], selection: Binding(get: { model.access(who) },
                                                                                       set: { model.setAccess(who, $0) })) {
                        Text("Read & Write").tag(3)
                        Text("Read only").tag(1)
                        Text("Write only").tag(2)
                        Text("No Access").tag(0)
                    }
                    .disabled(model.info?.ownedByMe != true || model.info?.locked == true)
                }
                row("Permissions", model.info?.permissions ?? "").monospaced()
                if model.info?.ownedByMe == false {
                    Text("Only the owner can change these.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, idealWidth: 400, minHeight: 420)
    }

    private var sizeSummary: String {
        if let s = model.info?.size { return bytes(s) }
        if let f = model.folderSize { return bytes(f.logical) }
        return "--"
    }

    private var sizeDetail: String {
        if let s = model.info?.size {
            return "\(bytes(s)) (\(s.formatted()) bytes)" + (model.info?.allocated.map { "\n\(bytes($0)) on disk" } ?? "")
        }
        if let f = model.folderSize {
            return "\(bytes(f.logical)) for \(f.items.formatted()) items\n\(bytes(f.allocated)) on disk"
        }
        return model.computingSize ? "Calculating…" : "--"
    }
}

/// One Get Info window per item, like Finder.
@MainActor
final class GetInfoWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [URL: GetInfoWindowController] = [:]
    private let model: InfoModel

    static func show(_ item: FileItem) {
        let key = item.url.standardizedFileURL
        if let existing = open[key] {
            existing.model.reload()
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = GetInfoWindowController(item: item)
        open[key] = controller
        controller.window?.center()
        if let offset = open.count > 1 ? CGFloat(open.count - 1) * 22 : nil, let frame = controller.window?.frame {
            controller.window?.setFrameOrigin(NSPoint(x: frame.minX + offset, y: frame.minY - offset))
        }
        controller.showWindow(nil)
    }

    private init(item: FileItem) {
        model = InfoModel(item: item)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(item.displayName) Info"
        window.contentView = NSHostingView(rootView: InfoView(model: model))
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
        Self.open = Self.open.filter { $0.value !== self }
    }
}

extension BrowserViewController {
    /// ⌘I: one window per selected item (up to 10), or the current folder when nothing is selected.
    @objc func getInfo(_ sender: Any?) {
        let items = Array(state.selectedItems.prefix(10))
        if !items.isEmpty {
            for item in items { GetInfoWindowController.show(item) }
        } else if let url = state.location.folderURL {
            Task {
                if let item = await Task.detached(operation: { DirectoryLoader.shared.stat(url) }).value {
                    GetInfoWindowController.show(item)
                }
            }
        }
    }
}
