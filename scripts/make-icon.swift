// Draws Foray's app icon: a big magnifier with a golden folder seen through the lens ("find your
// files"), filling the tile so it reads in a small Dock. Writes:
//   Resources/Foray.icon         the layered icon for macOS 26/27 (Icon Composer format: a fill and
//                                glass layers; macOS adds the glass, dark, clear and tinted looks)
//   Resources/Foray.icns         the same design flat, for test builds and older tools
//   Resources/Foray-Dev.icns     with a DEV band, for "Foray Dev" test builds
//   Resources/Icon/Foray-1024.png  for the README
//   swift scripts/make-icon.swift
import AppKit

let cs = CGColorSpaceCreateDeviceRGB()
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a).cgColor
}
func grad(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient { CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)! }

// Palette.
let teal = (top: UInt32(0x0E7C86), bottom: UInt32(0x18C2AE))
let navy = UInt32(0x2D2F7A)
let folderBack = (UInt32(0xF3C766), UInt32(0xE6A93A)), folderFront = (UInt32(0xFFE29A), UInt32(0xF8C65A))

// Geometry, on a 1024 canvas where the icon square fills the canvas (Icon Composer's layout).
let center = CGPoint(x: 433, y: 599), radius: CGFloat = 292, rim: CGFloat = 54
let handleAngle: CGFloat = .pi / 4   // towards the lower right

func render(_ size: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: Layers (each on its own transparent canvas)

func drawLens(_ cg: CGContext) {
    let lens = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    cg.saveGState(); cg.addEllipse(in: lens); cg.clip()
    cg.drawLinearGradient(grad([c(0xE8FBFF), c(0xB5ECF2)]), start: CGPoint(x: 0, y: lens.maxY), end: CGPoint(x: 0, y: lens.minY), options: [])
    cg.restoreGState()
}

func drawFolder(_ cg: CGContext) {
    let rect = CGRect(x: center.x - 210, y: center.y - 155, width: 420, height: 280)
    let tabW = rect.width * 0.38, tabH = rect.height * 0.12, r = rect.width * 0.05
    let back = CGMutablePath()
    back.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
    back.addRoundedRect(in: CGRect(x: rect.minX, y: rect.maxY - r, width: tabW, height: tabH + r), cornerWidth: r, cornerHeight: r)
    cg.saveGState(); cg.addPath(back); cg.clip()
    cg.drawLinearGradient(grad([c(folderBack.0), c(folderBack.1)]), start: CGPoint(x: 0, y: rect.maxY + tabH), end: CGPoint(x: 0, y: rect.minY), options: [])
    cg.restoreGState()
    let front = CGPath(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.80), cornerWidth: r, cornerHeight: r, transform: nil)
    cg.saveGState(); cg.addPath(front); cg.clip()
    cg.drawLinearGradient(grad([c(folderFront.0), c(folderFront.1)]), start: CGPoint(x: 0, y: rect.minY + rect.height * 0.8), end: CGPoint(x: 0, y: rect.minY), options: [])
    cg.restoreGState()
}

func drawRim(_ cg: CGContext) {
    cg.setFillColor(c(navy))
    // The ring (outer circle minus the lens)…
    let ring = CGMutablePath()
    ring.addEllipse(in: CGRect(x: center.x - radius - rim, y: center.y - radius - rim, width: (radius + rim) * 2, height: (radius + rim) * 2))
    ring.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    cg.addPath(ring)
    cg.fillPath(using: .evenOdd)
    // …and the handle, filled on its own so where it meets the ring stays solid.
    var t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: handleAngle)
    cg.addPath(CGPath(roundedRect: CGRect(x: -72, y: -radius - rim - 250, width: 144, height: 290), cornerWidth: 72, cornerHeight: 72, transform: &t))
    cg.fillPath()
}

// MARK: The flat icon (tile, background, layers, simple shading)

func drawFlat(_ cg: CGContext, dev: Bool) {
    // Tile: the macOS icon grid's 824 pt rounded square inside the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: c(0x000000, 0.22))
    cg.addPath(path); cg.setFillColor(c(0x000000)); cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(path); cg.clip()
    cg.drawLinearGradient(grad([c(teal.top), c(teal.bottom)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // The layers, scaled from the full canvas into the tile.
    cg.translateBy(x: tile.minX, y: tile.minY)
    cg.scaleBy(x: tile.width / 1024, y: tile.height / 1024)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 28, color: c(0x000000, 0.35))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    drawRim(cg)
    cg.endTransparencyLayer()
    cg.restoreGState()
    drawLens(cg)
    let lens = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    cg.saveGState(); cg.addEllipse(in: lens); cg.clip()
    drawFolder(cg)
    cg.drawLinearGradient(grad([c(0xffffff, 0.5), c(0xffffff, 0)]), start: CGPoint(x: lens.minX, y: lens.maxY), end: CGPoint(x: lens.midX, y: lens.midY), options: [])
    cg.restoreGState()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(path); cg.clip()
    cg.drawLinearGradient(grad([c(0xffffff, 0.18), c(0xffffff, 0)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    if dev {
        cg.setFillColor(c(0xED4D3D, 0.95))
        cg.fill(CGRect(x: 100, y: 120, width: 824, height: 150))
        let label = NSAttributedString(string: "DEV", attributes: [
            .font: NSFont.systemFont(ofSize: 120, weight: .heavy), .foregroundColor: NSColor.white, .kern: 12,
        ])
        label.draw(at: NSPoint(x: 512 - label.size().width / 2, y: 128))
    }
    cg.restoreGState()
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")

func makeIcns(dev: Bool) throws {
    let name = dev ? "Foray-Dev" : "Foray"
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let file = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try render(base * scale) { drawFlat($0, dev: dev) }.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(file))
        }
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("\(name).icns").path]
    try p.run()
    p.waitUntilExit()
    print(p.terminationStatus == 0 ? "Resources/\(name).icns" : "iconutil failed for \(name)")
}

/// The layered icon: fill + three groups (front to back): rim and handle (glass), the folder, the lens.
func makeLayeredIcon() throws {
    let icon = resources.appendingPathComponent("Foray.icon")
    let assets = icon.appendingPathComponent("Assets")
    try? FileManager.default.removeItem(at: icon)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    for (file, draw) in [("rim.png", drawRim), ("folder.png", drawFolder), ("lens.png", drawLens)] as [(String, (CGContext) -> Void)] {
        try render(1024, draw).representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent(file))
    }
    func layer(_ name: String, glass: Bool) -> [String: Any] {
        ["image-name": "\(name).png", "name": name, "glass": glass,
         "position": ["scale": 1, "translation-in-points": [0, 0]]]
    }
    func group(_ layers: [[String: Any]], shadow: String) -> [String: Any] {
        ["layers": layers, "shadow": ["kind": shadow, "opacity": 0.5], "translucency": ["enabled": true, "value": 0.4]]
    }
    let json: [String: Any] = [
        "fill": ["automatic-gradient": "extended-srgb:0.05490,0.56471,0.58431,1.00000"],
        "groups": [
            group([layer("rim", glass: true)], shadow: "layer-color"),
            group([layer("folder", glass: false)], shadow: "neutral"),
            group([layer("lens", glass: true)], shadow: "neutral"),
        ],
        "supported-platforms": ["squares": ["macOS"]],
    ]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: icon.appendingPathComponent("icon.json"))
    print("Resources/Foray.icon")
}

try FileManager.default.createDirectory(at: resources.appendingPathComponent("Icon"), withIntermediateDirectories: true)
try render(1024) { drawFlat($0, dev: false) }.representation(using: .png, properties: [:])!
    .write(to: resources.appendingPathComponent("Icon/Foray-1024.png"))
try makeIcns(dev: false)
try makeIcns(dev: true)
try makeLayeredIcon()
