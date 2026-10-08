import AppKit
import QuickLookThumbnailing
import RFModel
import UniformTypeIdentifiers

/// Icons and thumbnails (DESIGN.md §5.5). Generic icons are cached per type; per-file icons only
/// for apps, volumes, aliases and custom icons. Thumbnails are requested for visible cells only,
/// with `[.icon, .thumbnail]` (apps fail with `.thumbnail` alone, M0 S7), and never block.
@MainActor
final class IconProvider {
    static let shared = IconProvider()

    private var typeIcons: [String: NSImage] = [:]
    private let fileIcons = NSCache<NSString, NSImage>()
    private let thumbnails = NSCache<NSString, NSImage>()
    private var inFlight: [String: QLThumbnailGenerator.Request] = [:]

    init() {
        fileIcons.countLimit = 2_000
        thumbnails.totalCostLimit = 200 * 1024 * 1024
    }

    static func needsFileIcon(_ item: FileItem) -> Bool {
        item.flags.contains(.hasCustomIcon) || item.flags.contains(.mountPoint) || item.flags.contains(.alias)
            || item.contentType.conforms(to: .application) || item.flags.contains(.package)
            || (item.isNavigableFolder && specialFolderParents.contains(item.url.deletingLastPathComponent().path))
    }

    /// Folders here can have location-based icons (Desktop, Documents, Applications, Users, …).
    private static let specialFolderParents: Set<String> = [
        "/", FileManager.default.homeDirectoryForCurrentUser.path, FileManager.default.homeDirectoryForCurrentUser.path + "/",
    ]

    /// Best icon available right now, without I/O.
    func icon(for item: FileItem) -> NSImage {
        if let cached = fileIcons.object(forKey: item.url.path as NSString) { return cached }
        let key = item.isNavigableFolder ? "public.folder" : item.contentType.identifier
        if let hit = typeIcons[key] { return hit }
        let image = NSWorkspace.shared.icon(for: item.isNavigableFolder ? .folder : item.contentType)
        typeIcons[key] = image
        return image
    }

    /// Per-file icon, loaded off-main; `completion` runs on the main actor if it differs from the type icon.
    func loadFileIcon(for item: FileItem, completion: @escaping @MainActor (NSImage) -> Void) {
        guard Self.needsFileIcon(item) else { return }
        let path = item.url.path
        if let cached = fileIcons.object(forKey: path as NSString) { return completion(cached) }
        Task.detached(priority: .utility) {
            let image = NSWorkspace.shared.icon(forFile: path)
            await MainActor.run {
                self.fileIcons.setObject(image, forKey: path as NSString)
                completion(image)
            }
        }
    }

    func cachedThumbnail(for item: FileItem, size: CGFloat) -> NSImage? {
        thumbnails.object(forKey: thumbnailKey(item, size) as NSString)
    }

    func loadThumbnail(for item: FileItem, size: CGFloat, scale: CGFloat, completion: @escaping @MainActor (NSImage) -> Void) {
        guard !item.isNavigableFolder, !item.flags.contains(.mountPoint) else { return }
        let key = thumbnailKey(item, size)
        if let hit = thumbnails.object(forKey: key as NSString) { return completion(hit) }
        guard inFlight[key] == nil else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url, size: CGSize(width: size, height: size), scale: scale, representationTypes: [.icon, .thumbnail])
        inFlight[key] = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.type == .thumbnail ? rep?.nsImage : nil
            Task { @MainActor in
                self.inFlight[key] = nil
                guard let image else { return }
                self.thumbnails.setObject(image, forKey: key as NSString, cost: Int(size * size * scale * scale * 4))
                completion(image)
            }
        }
    }

    func cancelThumbnail(for item: FileItem, size: CGFloat) {
        let key = thumbnailKey(item, size)
        if let request = inFlight.removeValue(forKey: key) { QLThumbnailGenerator.shared.cancel(request) }
    }

    private func thumbnailKey(_ item: FileItem, _ size: CGFloat) -> String {
        "\(item.id)|\(item.modified?.timeIntervalSince1970 ?? 0)|\(item.size ?? 0)|\(Int(size))"
    }
}
