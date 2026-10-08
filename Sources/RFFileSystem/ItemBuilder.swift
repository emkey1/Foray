import CFastFS
import Foundation
import RFModel
import Synchronization
import UniformTypeIdentifiers

/// Turns raw getattrlistbulk records into `FileItem`s without per-item LaunchServices calls
/// (DESIGN.md §5.4): the type comes from the extension, memoized.
enum ItemBuilder {
    // sys/vnode.h object types
    static let VREG: UInt32 = 1, VDIR: UInt32 = 2, VLNK: UInt32 = 5
    // FileInfo.finderFlags
    static let kIsAlias: UInt16 = 0x8000, kIsInvisible: UInt16 = 0x4000, kHasBundle: UInt16 = 0x2000
    static let kHasCustomIcon: UInt16 = 0x0400
    // st_flags
    static let UF_IMMUTABLE: UInt32 = 0x0000_0002, UF_HIDDEN: UInt32 = 0x0000_8000
    static let SF_DATALESS: UInt32 = 0x4000_0000

    private static let fileTypes = Mutex<[String: UTType]>([:])
    private static let dirTypes = Mutex<[String: UTType]>([:])

    static func make(_ e: rf_entry, in directory: URL) -> FileItem? {
        guard e.error == 0, let cName = e.name else { return nil }
        let name = String(cString: cName)
        let isDir = e.objtype == VDIR
        let ext = (name as NSString).pathExtension.lowercased()

        var flags: ItemFlags = []
        if isDir { flags.insert(.directory) }
        if e.objtype == VLNK { flags.insert(.symlink) }
        if e.finderflags & kIsAlias != 0 && !isDir { flags.insert(.alias) }
        if e.flags & UF_HIDDEN != 0 || e.finderflags & kIsInvisible != 0 || name.hasPrefix(".") { flags.insert(.hidden) }
        if e.flags & UF_IMMUTABLE != 0 { flags.insert(.locked) }
        if e.flags & SF_DATALESS != 0 { flags.insert(.dataless) }
        if e.finderflags & kHasCustomIcon != 0 { flags.insert(.hasCustomIcon) }
        if e.ismountpoint != 0 { flags.insert(.mountPoint) }
        if e.objtype == VREG && e.mode & 0o111 != 0 { flags.insert(.executable) }

        let type: UTType
        switch e.objtype {
        case VDIR:
            if e.ismountpoint != 0 {
                type = .volume
            } else {
                type = directoryType(ext: ext, hasBundleBit: e.finderflags & kHasBundle != 0)
                if type.conforms(to: .package) { flags.insert(.package) }
            }
        case VLNK:
            type = .symbolicLink
        default:
            if flags.contains(.alias) {
                type = .aliasFile
            } else if ext.isEmpty {
                type = flags.contains(.executable) ? .unixExecutable : .data
            } else {
                type = fileType(ext: ext)
            }
        }

        return FileItem(
            id: FileID(device: e.device, inode: e.fileid),
            url: directory.appendingPathComponent(name, isDirectory: isDir),
            name: name,
            contentType: type,
            flags: flags,
            size: isDir ? nil : e.size,
            allocatedSize: isDir ? nil : e.allocsize,
            created: date(e.crtime),
            modified: date(e.modtime),
            added: e.addedtime.tv_sec == 0 ? nil : date(e.addedtime))
    }

    static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
    }

    static func fileType(ext: String) -> UTType {
        if let hit = fileTypes.withLock({ $0[ext] }) { return hit }
        let t = UTType(filenameExtension: ext) ?? .data
        fileTypes.withLock { $0[ext] = t }
        return t
    }

    static func directoryType(ext: String, hasBundleBit: Bool) -> UTType {
        if ext.isEmpty { return hasBundleBit ? .package : .folder }
        let memoKey = ext + (hasBundleBit ? "+b" : "")
        if let hit = dirTypes.withLock({ $0[memoKey] }) { return hit }
        var t = UTType.folder
        if let declared = UTType(filenameExtension: ext, conformingTo: .directory), !declared.isDynamic {
            t = declared
        } else if hasBundleBit {
            t = .package
        }
        dirTypes.withLock { $0[memoKey] = t }
        return t
    }
}
