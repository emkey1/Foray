// Draws Foray's app icon and writes Resources/Foray.icns (and a 1024 px PNG for the README).
//   swift scripts/make-icon.swift
// A compass needle over a folder: a foray into your files. Drawn in code so it can be tweaked.
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    cg.scaleBy(x: size / 1024, y: size / 1024)

    // Tile: the macOS icon grid's 824 pt rounded square, with room for its shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    cg.addPath(tilePath)
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(tilePath)
    cg.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.13, green: 0.52, blue: 0.56, alpha: 1).cgColor,   // teal (bottom)
        NSColor(srgbRed: 0.20, green: 0.22, blue: 0.55, alpha: 1).cgColor,   // indigo (top)
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // A soft glow behind the needle.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 470, y: 580), startRadius: 0, endCenter: CGPoint(x: 470, y: 580), endRadius: 420, options: [])

    // Folder.
    let folder = CGMutablePath()
    folder.move(to: CGPoint(x: 210, y: 230))
    folder.addLine(to: CGPoint(x: 814, y: 230))
    folder.addArc(tangent1End: CGPoint(x: 834, y: 230), tangent2End: CGPoint(x: 834, y: 250), radius: 28)
    folder.addLine(to: CGPoint(x: 834, y: 580))
    folder.addArc(tangent1End: CGPoint(x: 834, y: 610), tangent2End: CGPoint(x: 804, y: 610), radius: 28)
    folder.addLine(to: CGPoint(x: 470, y: 610))
    folder.addLine(to: CGPoint(x: 430, y: 650))
    folder.addLine(to: CGPoint(x: 230, y: 650))
    folder.addArc(tangent1End: CGPoint(x: 190, y: 650), tangent2End: CGPoint(x: 190, y: 610), radius: 28)
    folder.addLine(to: CGPoint(x: 190, y: 250))
    folder.addArc(tangent1End: CGPoint(x: 190, y: 230), tangent2End: CGPoint(x: 210, y: 230), radius: 22)
    folder.closeSubpath()
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    cg.addPath(folder)
    cg.setFillColor(NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 1).cgColor)
    cg.fillPath()
    cg.restoreGState()
    // Folder front flap, slightly darker, so it reads as a folder at small sizes.
    let flap = CGPath(roundedRect: CGRect(x: 190, y: 230, width: 644, height: 330), cornerWidth: 28, cornerHeight: 28, transform: nil)
    cg.addPath(flap)
    cg.setFillColor(NSColor(srgbRed: 0.99, green: 0.97, blue: 0.92, alpha: 1).cgColor)
    cg.fillPath()

    // Compass ring.
    let center = CGPoint(x: 500, y: 450)
    cg.setStrokeColor(NSColor(srgbRed: 0.20, green: 0.22, blue: 0.55, alpha: 0.35).cgColor)
    cg.setLineWidth(14)
    cg.strokeEllipse(in: CGRect(x: center.x - 190, y: center.y - 190, width: 380, height: 380))
    for i in 0..<4 {
        let a = CGFloat(i) * .pi / 2
        cg.move(to: CGPoint(x: center.x + cos(a) * 160, y: center.y + sin(a) * 160))
        cg.addLine(to: CGPoint(x: center.x + cos(a) * 190, y: center.y + sin(a) * 190))
    }
    cg.strokePath()

    // Needle, tilted toward the upper left (not Safari's upper right); amber points the way.
    cg.saveGState()
    cg.translateBy(x: center.x, y: center.y)
    cg.rotate(by: .pi / 5)
    cg.setShadow(offset: CGSize(width: 6, height: -10), blur: 16, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    let north = CGMutablePath()
    north.move(to: CGPoint(x: 0, y: 330)); north.addLine(to: CGPoint(x: 58, y: 0)); north.addLine(to: CGPoint(x: -58, y: 0)); north.closeSubpath()
    let south = CGMutablePath()
    south.move(to: CGPoint(x: 0, y: -250)); south.addLine(to: CGPoint(x: 58, y: 0)); south.addLine(to: CGPoint(x: -58, y: 0)); south.closeSubpath()
    cg.addPath(north)
    cg.setFillColor(NSColor(srgbRed: 0.98, green: 0.62, blue: 0.10, alpha: 1).cgColor)
    cg.fillPath()
    cg.setShadow(offset: .zero, blur: 0, color: nil)
    cg.addPath(south)
    cg.setFillColor(NSColor(srgbRed: 0.33, green: 0.36, blue: 0.48, alpha: 1).cgColor)
    cg.fillPath()
    // Light edge on the north half (the side facing the light).
    let northRight = CGMutablePath()
    northRight.move(to: CGPoint(x: 0, y: 330)); northRight.addLine(to: CGPoint(x: -58, y: 0)); northRight.addLine(to: CGPoint(x: 0, y: 0)); northRight.closeSubpath()
    cg.addPath(northRight)
    cg.setFillColor(NSColor(srgbRed: 1.0, green: 0.80, blue: 0.38, alpha: 1).cgColor)
    cg.fillPath()
    cg.setFillColor(NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1).cgColor)
    cg.fillEllipse(in: CGRect(x: -26, y: -26, width: 52, height: 52))
    cg.restoreGState()

    // Top sheen.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.12).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Foray.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try draw(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/Icon/Foray-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/Foray.icns").path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Resources/Foray.icns" : "iconutil failed")
