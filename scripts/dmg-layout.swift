// Lays out the Foray disk image window: background picture, icon positions and size, no
// toolbar or sidebar, and Foray's icon on the disk. Writes the window settings straight into the
// volume's .DS_Store (the format Foray already reads for Put Back), so making a release doesn't
// need to script Finder.
//   swift scripts/dmg-layout.swift /Volumes/<mounted image> <path to Foray.icns>
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: dmg-layout.swift <volume> <icns>"); exit(2) }
let volume = URL(fileURLWithPath: args[1], isDirectory: true)
let icns = URL(fileURLWithPath: args[2])

// Window content size and icon centres (points, from the top left).
let size = CGSize(width: 640, height: 400)
let appCenter = CGPoint(x: 170, y: 190), appsCenter = CGPoint(x: 470, y: 190)

// MARK: Background (1x and 2x in one TIFF)

func background(scale: CGFloat) -> Data {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1).cgColor,
        NSColor(srgbRed: 0.90, green: 0.93, blue: 0.97, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(bg, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])
    // Accent strip at the top, in the icon's colours.
    let strip = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.20, green: 0.22, blue: 0.55, alpha: 1).cgColor,
        NSColor(srgbRed: 0.13, green: 0.52, blue: 0.56, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.saveGState()
    cg.clip(to: CGRect(x: 0, y: size.height - 6, width: size.width, height: 6))
    cg.drawLinearGradient(strip, start: .zero, end: CGPoint(x: size.width, y: 0), options: [])
    cg.restoreGState()

    func text(_ s: String, _ font: NSFont, _ color: NSColor, centerY: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let h = a.boundingRect(with: CGSize(width: size.width - 80, height: 200), options: [.usesLineFragmentOrigin]).height
        a.draw(with: CGRect(x: 40, y: size.height - centerY - h / 2, width: size.width - 80, height: h), options: [.usesLineFragmentOrigin])
    }
    text("Drag Foray to Applications", .systemFont(ofSize: 22, weight: .semibold), NSColor(srgbRed: 0.15, green: 0.17, blue: 0.30, alpha: 1), centerY: 52)

    // Arrow between the icons.
    let y = size.height - appCenter.y
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: 262, y: y))
    arrow.line(to: CGPoint(x: 366, y: y))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    NSColor(srgbRed: 0.13, green: 0.52, blue: 0.56, alpha: 0.9).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: 382, y: y))
    head.line(to: CGPoint(x: 360, y: y + 16))
    head.line(to: CGPoint(x: 360, y: y - 16))
    head.close()
    NSColor(srgbRed: 0.13, green: 0.52, blue: 0.56, alpha: 0.9).setFill()
    head.fill()

    text("Then open Foray from Applications. To see the Trash and other protected places,\nturn on Full Disk Access in Foray › Settings › Privacy.",
         .systemFont(ofSize: 12), NSColor(srgbRed: 0.35, green: 0.38, blue: 0.48, alpha: 1), centerY: 345)
    NSGraphicsContext.restoreGraphicsState()
    return rep.tiffRepresentation!
}

let hidden = volume.appendingPathComponent(".background", isDirectory: true)
try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
let tmp = FileManager.default.temporaryDirectory
try background(scale: 1).write(to: tmp.appendingPathComponent("bg1.tiff"))
try background(scale: 2).write(to: tmp.appendingPathComponent("bg2.tiff"))
let picture = hidden.appendingPathComponent("background.tiff")
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cat", tmp.appendingPathComponent("bg1.tiff").path, tmp.appendingPathComponent("bg2.tiff").path, "-out", picture.path]
try tiffutil.run()
tiffutil.waitUntilExit()

// Disk icon: Foray's, shown because the volume gets the custom-icon flag (SetFile -a C, in make-dmg.sh).
try? FileManager.default.removeItem(at: volume.appendingPathComponent(".VolumeIcon.icns"))
try FileManager.default.copyItem(at: icns, to: volume.appendingPathComponent(".VolumeIcon.icns"))

// MARK: .DS_Store

func plist(_ object: Any) -> Data { try! PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0) }

/// The background as a classic alias record (version 2), which Finder's icvp backgroundImageAlias
/// expects. Built by hand: the Alias Manager isn't available to Swift. Layout as in Apple's
/// Aliases.h and the open-source DMG builders: a fixed header, then tagged extras.
func alias(_ url: URL) -> Data? {
    var st = stat(), parentSt = stat()
    guard stat(url.path, &st) == 0, stat(url.deletingLastPathComponent().path, &parentSt) == 0,
          let v = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeCreationDateKey, .volumeURLKey]),
          let volumeName = v.volumeName, let mount = v.volume else { return nil }
    let hfsEpoch = Date(timeIntervalSince1970: -2_082_844_800)
    func hfs(_ d: Date?) -> UInt32 { UInt32(max(0, (d ?? Date()).timeIntervalSince(hfsEpoch))) }
    var d = Data()
    func put16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
    func put32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
    func pascal(_ s: String, _ size: Int) {
        let bytes = Array(s.utf8.prefix(size - 1))
        d.append(UInt8(bytes.count)); d.append(contentsOf: bytes); d.append(contentsOf: [UInt8](repeating: 0, count: size - 1 - bytes.count))
    }
    func tag(_ t: UInt16, _ bytes: [UInt8]) {
        put16(t); put16(UInt16(bytes.count)); d.append(contentsOf: bytes)
        if bytes.count % 2 == 1 { d.append(0) }
    }
    func utf16(_ s: String) -> [UInt8] {
        var b: [UInt8] = []
        let units = Array(s.utf16)
        withUnsafeBytes(of: UInt16(units.count).bigEndian) { b.append(contentsOf: $0) }
        for u in units { withUnsafeBytes(of: u.bigEndian) { b.append(contentsOf: $0) } }
        return b
    }
    let name = url.lastPathComponent, parentName = url.deletingLastPathComponent().lastPathComponent
    let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    put32(0); put16(0); put16(2); put16(0)              // creator, size (patched below), version 2, kind file
    pascal(volumeName, 28)
    put32(hfs(v.volumeCreationDate)); put16(0x482B)     // 'H+'
    put16(5)                                            // ejectable disk
    put32(UInt32(truncatingIfNeeded: parentSt.st_ino))
    pascal(name, 64)
    put32(UInt32(truncatingIfNeeded: st.st_ino)); put32(hfs(created))
    put32(0); put32(0)                                  // file type, creator
    put16(0xFFFF); put16(0xFFFF)                        // nlvlFrom, nlvlTo
    put32(0); put16(0)                                  // volume attributes, fs id
    d.append(contentsOf: [UInt8](repeating: 0, count: 10))
    tag(0, Array(parentName.utf8))
    var cnid: [UInt8] = []
    withUnsafeBytes(of: UInt32(truncatingIfNeeded: parentSt.st_ino).bigEndian) { cnid.append(contentsOf: $0) }
    tag(1, cnid)
    tag(2, Array("\(volumeName):\(parentName):\(name)".utf8))
    tag(14, utf16(name))
    tag(15, utf16(volumeName))
    let relative = String(url.path.dropFirst(mount.path.count))
    tag(18, Array((relative.hasPrefix("/") ? relative : "/" + relative).utf8))
    tag(19, Array(mount.path.utf8))
    put16(0xFFFF); put16(0)
    let size = UInt16(d.count)
    d[4] = UInt8(size >> 8); d[5] = UInt8(size & 0xFF)
    return d
}

let bounds = "{{120, 120}, {\(Int(size.width)), \(Int(size.height) + 28)}}"
var icvp: [String: Any] = [
    "arrangeBy": "none", "backgroundType": 2, "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
    "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0, "iconSize": 128.0, "labelOnBottom": true,
    "showIconPreview": true, "showItemInfo": false, "textSize": 13.0, "viewOptionsVersion": 1,
]
if let a = alias(picture) { icvp["backgroundImageAlias"] = a }
let bwsp: [String: Any] = [
    "ContainerShowSidebar": false, "PreviewPaneVisibility": false, "ShowPathbar": false, "ShowSidebar": false,
    "ShowStatusBar": false, "ShowTabView": false, "ShowToolbar": false, "SidebarWidth": 0, "WindowBounds": bounds,
]
let bookmark = try picture.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

enum Value { case blob(Data), long(UInt32), type(String) }
func iloc(_ p: CGPoint) -> Data {
    var d = Data()
    for v in [UInt32(p.x), UInt32(p.y), 0xFFFF_FFFF, 0xFFFF_0000] { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
    return d
}
var records: [(name: String, code: String, value: Value)] = [
    (".", "bwsp", .blob(plist(bwsp))), (".", "icvl", .type("icnv")), (".", "icvp", .blob(plist(icvp))),
    (".", "pBBk", .blob(bookmark)), (".", "vSrn", .long(1)), (".", "vstl", .type("icnv")),
    ("Applications", "Iloc", .blob(iloc(appsCenter))), ("Foray.app", "Iloc", .blob(iloc(appCenter))),
]
records.sort { ($0.name.lowercased(), $0.code) < ($1.name.lowercased(), $1.code) }

func u32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
var leaf = Data()
u32(0, &leaf)                        // leaf node: no children
u32(UInt32(records.count), &leaf)
for r in records {
    let units = Array(r.name.utf16)
    u32(UInt32(units.count), &leaf)
    for u in units { withUnsafeBytes(of: u.bigEndian) { leaf.append(contentsOf: $0) } }
    leaf.append(contentsOf: Array(r.code.utf8))
    switch r.value {
    case .blob(let d): leaf.append(contentsOf: Array("blob".utf8)); u32(UInt32(d.count), &leaf); leaf.append(d)
    case .long(let v): leaf.append(contentsOf: Array("long".utf8)); u32(v, &leaf)
    case .type(let t): leaf.append(contentsOf: Array("type".utf8)); leaf.append(contentsOf: Array(t.utf8))
    }
}
precondition(leaf.count <= 4096, "layout records don't fit one node")

// Buddy allocator layout (offsets are +4 in the file), as macOS lays out a small store:
//   0x40 DSDB header (32), 0x1000 allocator info (2048), 0x2000 the records node (4096).
var info = Data()
u32(3, &info); u32(0, &info)
for a: UInt32 in [0x1000 | 11, 0x40 | 5, 0x2000 | 12] { u32(a, &info) }
for _ in 3..<256 { u32(0, &info) }
u32(1, &info); info.append(4); info.append(contentsOf: Array("DSDB".utf8)); u32(1, &info)
let free: [Int: [UInt32]] = [5: [0x20, 0x60], 7: [0x80], 8: [0x100], 9: [0x200], 10: [0x400], 11: [0x800, 0x1800], 12: [0x3000]]
for i in 0..<32 {
    let list = free[i] ?? (i >= 14 && i <= 30 ? [UInt32(1) << UInt32(i)] : [])
    u32(UInt32(list.count), &info)
    for o in list { u32(o, &info) }
}
var dsdb = Data()
for v: UInt32 in [2, 0, UInt32(records.count), 1, 0x1000] { u32(v, &dsdb) }

var file = Data(count: 0x3004)
func put(_ d: Data, at offset: Int) { file.replaceSubrange((offset + 4)..<(offset + 4 + d.count), with: d) }
var header = Data()
u32(1, &header); header.append(contentsOf: Array("Bud1".utf8)); u32(0x1000, &header); u32(0x800, &header); u32(0x1000, &header)
header.append(Data([0, 0, 0x01, 0x0C, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
file.replaceSubrange(0..<header.count, with: header)
put(dsdb, at: 0x40)
put(info, at: 0x1000)
put(leaf, at: 0x2000)
try file.write(to: volume.appendingPathComponent(".DS_Store"))
print("laid out \(volume.path)")
