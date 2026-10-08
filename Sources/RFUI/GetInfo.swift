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
    var locked = false
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
            info.locked = st.st_flags & UInt32(UF_IMMUTABLE) != 0
        }
        info.tags = Tags.read(at: item.url)
        info.comment = Self.comment(item.url)
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

    /// The Spotlight comment Finder stores in an xattr (M0 S6: Finder also writes it there).
    static func comment(_ url: URL) -> String {
        let name = "com.apple.metadata:kMDItemFinderComment"
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return "" }
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil) as? String) ?? ""
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
                if model.info?.locked == true { row("Locked", "Yes") }
            }
            if let more = model.info?.more, !more.isEmpty {
                Section("More Info") {
                    ForEach(Array(more.enumerated()), id: \.offset) { _, pair in row(pair.0, pair.1) }
                }
            }
            Section("Name & Extension") {
                TextField("Name", text: $model.editedName).onSubmit { model.commitName() }
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
            if let comment = model.info?.comment, !comment.isEmpty {
                Section("Comments") { Text(comment).textSelection(.enabled) }
            }
            if let app = model.info?.defaultApp {
                Section("Opens With") { Text(app) }
            }
            Section("Sharing & Permissions") {
                row("Owner", model.info?.owner ?? "")
                row("Group", model.info?.group ?? "")
                row("Permissions", model.info?.permissions ?? "").monospaced()
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
