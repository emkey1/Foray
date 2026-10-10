#if DEBUG
import AppKit
import Foundation
import ImageIO
import RFFileSystem
import RFModel
import RFOperations
import UniformTypeIdentifiers

/// Takes screenshots that are safe to publish (scripts/screenshots.sh). Debug builds only: none
/// of this is in a released Foray.
///
/// The script launches the test app with `RF_SCREENSHOTS` set to an output folder. Instead of its
/// usual windows the app then shows invented files (made by `DemoContent`, on a disk image the
/// script mounts as "Atlas") with a stand-in sidebar, photographs each window in light and dark,
/// and quits. Nothing from the Mac it runs on appears: no user name, disks, network computers or
/// tags. It uses a private settings store, so the test app's own settings aren't touched.
@MainActor
public enum ScreenshotStudio {
    private static var output = URL(fileURLWithPath: NSTemporaryDirectory())
    private static var root = URL(fileURLWithPath: NSTemporaryDirectory())

    /// Call first thing at launch. True if this launch is a screenshot run (the caller then skips
    /// everything else); the app quits by itself when the pictures are taken.
    public static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["RF_SCREENSHOTS"], let demo = env["RF_DEMO_ROOT"] else { return false }
        output = URL(fileURLWithPath: out, isDirectory: true)
        root = URL(fileURLWithPath: demo, isDirectory: true)
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("foray-screenshots-\(getpid())", isDirectory: true)
        AppModel.shared = AppModel(store: AppSupportStore(directory: store.appendingPathComponent("store")))
        AppModel.shared.setSettingsModel(.perFolder)   // so two panes can show two different views
        OperationCenter.shared = OperationCenter(journal: OperationJournal(store: AppSupportStore(directory: store.appendingPathComponent("journal"))), trash: { $0 })
        SidebarViewController.sectionsForScreenshots = { _ in sidebar(root) }
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try DemoContent.make(at: root)
                await takeAll()
            } catch {
                FileHandle.standardError.write(Data("screenshots: \(error.localizedDescription)\n".utf8))
            }
            try? FileManager.default.removeItem(at: store)
            FileManager.default.createFile(atPath: output.appendingPathComponent(".done").path, contents: nil)
            exit(0)   // straight out: no session to save, nothing to confirm
        }
        return true
    }

    /// A sidebar like a real one, with nothing real in it.
    private static func sidebar(_ root: URL) -> [SidebarViewController.Node] {
        typealias Node = SidebarViewController.Node
        func symbol(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        func place(_ title: String, _ icon: String, _ path: String) -> Node {
            Node(title: title, location: .folder(URL(fileURLWithPath: path, isDirectory: true)), icon: symbol(icon))
        }
        func demo(_ name: String) -> Node {
            Node(title: name, location: .folder(root.appendingPathComponent(name, isDirectory: true)), icon: symbol("folder"))
        }
        func tag(_ name: String, _ color: TagColor) -> Node {
            Node(title: name, location: .search(SearchQuery(text: "tag:\"\(name)\"", scope: .thisMac)), icon: TagDotsView.image(for: color))
        }
        return [
            Node(title: "Favorites", children: [
                Node(title: "Recents", location: .recents, icon: symbol("clock")),
                place("Applications", "app.dashed", "/Applications"),
                place("Desktop", "menubar.dock.rectangle", "/private/var/empty/Desktop"),
                place("Documents", "doc", "/private/var/empty/Documents"),
                place("Downloads", "arrow.down.circle", "/private/var/empty/Downloads"),
                demo("Projects"), demo("Photos"), demo("Paperwork"),
            ]),
            Node(title: "Cloud", children: [place("iCloud Drive", "icloud", "/private/var/empty/iCloud")]),
            Node(title: "Locations", children: [
                Node(title: "Computer", location: .computer, icon: symbol("desktopcomputer")),
                place("Macintosh HD", "internaldrive", "/"),
                Node(title: root.lastPathComponent, location: .folder(root), icon: symbol("externaldrive"), ejectURL: root),
                Node(title: "Trash", location: .trash, icon: TrashUI.icon),
            ]),
            Node(title: "Tags", children: [tag("Red", .red), tag("Orange", .orange), tag("Green", .green), tag("Blue", .blue)]),
        ]
    }

    private static func wait(_ seconds: Double = 15, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
    }

    private static func folder(_ path: String) -> URL { root.appendingPathComponent(path, isDirectory: true) }

    /// A window on `path`, set up by `prepare`, photographed in light and dark.
    private static func shoot(_ name: String, _ path: String, size: NSSize = NSSize(width: 1180, height: 720),
                       settle: Double = 2.5, _ prepare: @MainActor (BrowserWindowController) async -> Void) async {
        NSApplication.shared.setActivationPolicy(.regular)
        let c = BrowserWindowController(location: .folder(folder(path)))
        guard let window = c.window else { return }
        window.setContentSize(size)
        window.center()
        c.showWindow(nil)
        await wait { c.browser.state.loadState == .complete }
        await prepare(c)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            // A front, key window: the toolbar and selection are drawn at full strength.
            await comeToFront()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(c.browser.content?.firstResponderView)
            // Thumbnails, the toolbar's glass and the selection highlight all settle a moment later.
            try? await Task.sleep(for: .seconds(settle))
            // The script takes the picture (it has the Screen Recording permission, the app
            // doesn't need it): leave a request naming the window, and wait for it to be collected.
            let request = output.appendingPathComponent(".request")
            try? "\(window.windowNumber) \(name)-\(suffix).png".write(to: request, atomically: true, encoding: .utf8)
            await wait(20) { !FileManager.default.fileExists(atPath: request.path) }
            if FileManager.default.fileExists(atPath: request.path) { exit(1) }   // the script has gone away
        }
        window.close()
    }

    /// The script starts the app with `open`, so macOS lets it come to the front.
    private static func comeToFront() async {
        let app = NSApplication.shared
        for _ in 0..<10 where !app.isActive {
            app.activate()
            try? await Task.sleep(for: .milliseconds(200))
        }
        if !app.isActive { FileHandle.standardError.write(Data("screenshots: couldn't come to the front; windows will look inactive\n".utf8)) }
    }

    private static func select(_ state: BrowserState, _ names: [String]) async {
        await wait { Set(names).isSubset(of: Set(state.snapshot.items.map(\.name))) }
        state.select(names: names)
    }

    private static func icons() async {
        await shoot("1-icons", "Photos") { c in
            c.browser.state.updatePresentation {
                $0.mode = .icon
                $0.icon.iconSize = 128
                $0.icon.gridSpacing = 30
            }
            await select(c.browser.state, ["Glacier Lake.jpg"])
        }
    }

    private static func list() async {
        await shoot("2-list", "Projects") { c in
            let state = c.browser.state
            state.updatePresentation { $0.mode = .list }
            await wait { state.snapshot.items.contains { $0.name == "Harbor Website" } }
            if let project = state.snapshot.items.first(where: { $0.name == "Harbor Website" }) { state.expand(project) }
            await wait(3) { !state.children.isEmpty }
            await select(state, ["Quarterly Report Q2.pdf", "Quarterly Report Q3.pdf"])
        }
    }

    private static func search() async {
        await shoot("3-search", "Projects", settle: 3.5) { c in
            c.browser.state.updatePresentation { $0.mode = .list }
            c.browser.state.runSearch(SearchQuery(text: "report kind:pdf", scope: .folder(folder("Projects"), recursive: true)))
            await wait { c.browser.state.searchStatus?.isRunning == false }
        }
    }

    private static func twoPanes() async {
        await shoot("4-two-panes", "Projects", size: NSSize(width: 1380, height: 740)) { c in
            c.browser.state.updatePresentation { $0.mode = .list }
            c.setDualPane(true, location: .folder(folder("Photos")))
            await wait { c.panes.allSatisfy { $0.state.loadState == .complete } }
            c.panes[1].state.updatePresentation {
                $0.mode = .icon
                $0.icon.iconSize = 88
            }
            await select(c.panes[0].state, ["Quarterly Report Q1.pdf"])
            c.setActivePane(0)
        }
    }

    private static func gallery() async {
        await shoot("5-gallery", "Photos") { c in
            c.browser.state.updatePresentation { $0.mode = .gallery }
            await select(c.browser.state, ["Harbor Lights.jpg"])
        }
    }

    private static func columns() async {
        await shoot("6-columns", "Projects/Harbor Website") { c in
            c.browser.state.updatePresentation { $0.mode = .column }
            await select(c.browser.state, ["Homepage.png"])
        }
    }

    private static func takeAll() async {
        await icons()
        await list()
        await search()
        await twoPanes()
        await gallery()
        await columns()
    }
}

/// Invented files for the screenshots: pictures, PDFs and notes drawn here, plus empty stand-ins
/// (with believable sizes) for kinds that can't be made up easily.
enum DemoContent {
    static func make(at root: URL) throws {
        let fm = FileManager.default
        func dir(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        var day = 0
        /// Each file is a little older than the one before, so dates vary.
        func stamp(_ url: URL) {
            day += 1
            let date = Date().addingTimeInterval(-Double(day) * 86_400 * 1.7 - Double(day * 4_321 % 80_000))
            try? fm.setAttributes([.modificationDate: date, .creationDate: date.addingTimeInterval(-86_400 * 3)], ofItemAtPath: url.path)
        }
        func text(_ url: URL, _ body: String) { try? body.write(to: url, atomically: true, encoding: .utf8); stamp(url) }
        /// A file of the right kind and size with nothing in it (it takes no space on disk).
        func standIn(_ url: URL, megabytes: Double) {
            fm.createFile(atPath: url.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.truncate(atOffset: UInt64(megabytes * 1_000_000))
                try? handle.close()
            }
            stamp(url)
        }

        let photos = try dir("Photos")
        let scenes = ["Coastline", "Dunes at Dusk", "Pine Ridge", "Harbor Lights", "Glacier Lake", "Canyon Trail", "Morning Fog",
                      "Lighthouse Point", "Wildflower Meadow", "Salt Flats", "Northern Sky", "Orchard Rows", "River Bend"]
        for (i, name) in scenes.enumerated() {
            let url = photos.appendingPathComponent("\(name).jpg")
            writeImage(landscape(seed: i, size: CGSize(width: 1600, height: 1067)), to: url, type: .jpeg)
            stamp(url)
        }
        standIn(photos.appendingPathComponent("Trip Highlights.mov"), megabytes: 482.6)
        pdf(photos.appendingPathComponent("Contact Sheet.pdf"), title: "Contact Sheet", pages: 2, accent: 3); stamp(photos.appendingPathComponent("Contact Sheet.pdf"))

        let projects = try dir("Projects")
        let harbor = try dir("Projects/Harbor Website")
        pdf(harbor.appendingPathComponent("Creative Brief.pdf"), title: "Harbor Website: Creative Brief", pages: 4, accent: 0); stamp(harbor.appendingPathComponent("Creative Brief.pdf"))
        writeImage(mockup(seed: 1), to: harbor.appendingPathComponent("Homepage.png"), type: .png); stamp(harbor.appendingPathComponent("Homepage.png"))
        writeImage(mockup(seed: 4), to: harbor.appendingPathComponent("Pricing Page.png"), type: .png); stamp(harbor.appendingPathComponent("Pricing Page.png"))
        pdf(harbor.appendingPathComponent("Style Guide.pdf"), title: "Style Guide", pages: 9, accent: 1); stamp(harbor.appendingPathComponent("Style Guide.pdf"))
        text(harbor.appendingPathComponent("Launch Checklist.md"), "# Launch checklist\n\n- [x] Final copy review\n- [x] Image compression pass\n- [ ] Redirects from the old site\n- [ ] Analytics\n- [ ] Announce\n")
        text(harbor.appendingPathComponent("Sitemap.txt"), "Home\n  About\n  Services\n    Moorings\n    Repairs\n  Pricing\n  Contact\n")
        let assets = try dir("Projects/Harbor Website/Assets")
        writeImage(landscape(seed: 20, size: CGSize(width: 1600, height: 700)), to: assets.appendingPathComponent("Hero.jpg"), type: .jpeg); stamp(assets.appendingPathComponent("Hero.jpg"))
        writeImage(mockup(seed: 7), to: assets.appendingPathComponent("Logo Sheet.png"), type: .png); stamp(assets.appendingPathComponent("Logo Sheet.png"))
        standIn(assets.appendingPathComponent("Icons.zip"), megabytes: 3.4)

        let trail = try dir("Projects/Trail Guide App")
        pdf(trail.appendingPathComponent("Roadmap Report.pdf"), title: "Trail Guide: Roadmap Report", pages: 6, accent: 2); stamp(trail.appendingPathComponent("Roadmap Report.pdf"))
        writeImage(mockup(seed: 9), to: trail.appendingPathComponent("Screens.png"), type: .png); stamp(trail.appendingPathComponent("Screens.png"))
        text(trail.appendingPathComponent("Release Notes.md"), "# 2.1\n\n- Offline maps for saved trails\n- Elevation profile on the trail page\n- Fixes for the compass on older phones\n")
        let source = try dir("Projects/Trail Guide App/Source")
        text(source.appendingPathComponent("TrailList.swift"), "import SwiftUI\n\nstruct TrailList: View {\n    let trails: [Trail]\n\n    var body: some View {\n        List(trails) { trail in\n            TrailRow(trail: trail)\n        }\n    }\n}\n")
        text(source.appendingPathComponent("Trail.swift"), "struct Trail: Identifiable {\n    let id: Int\n    var name: String\n    var kilometers: Double\n    var climb: Int\n}\n")

        let annual = try dir("Projects/Annual Report 2026")
        pdf(annual.appendingPathComponent("Annual Report Draft.pdf"), title: "Annual Report 2026", pages: 28, accent: 4); stamp(annual.appendingPathComponent("Annual Report Draft.pdf"))
        standIn(annual.appendingPathComponent("Figures.xlsx"), megabytes: 0.21)
        standIn(annual.appendingPathComponent("Board Presentation.key"), megabytes: 18.3)
        text(annual.appendingPathComponent("Interview Notes.txt"), "Themes from the staff interviews\n\n1. The new booking system saved the most time.\n2. Weekend coverage is still thin.\n3. People want the workshop days back.\n")

        for (i, quarter) in ["Q1", "Q2", "Q3"].enumerated() {
            let url = projects.appendingPathComponent("Quarterly Report \(quarter).pdf")
            pdf(url, title: "Quarterly Report \(quarter)", pages: 12 + i * 2, accent: i)
            stamp(url)
        }
        pdf(projects.appendingPathComponent("Report Template.pdf"), title: "Report Template", pages: 3, accent: 5); stamp(projects.appendingPathComponent("Report Template.pdf"))
        text(projects.appendingPathComponent("Ideas.txt"), "Ideas for next year\n\n- A printed trail map\n- Guest moorings page\n- Photo competition\n")

        let paperwork = try dir("Paperwork")
        for (i, name) in ["Invoice 1042", "Invoice 1043", "Workshop Agenda", "Travel Itinerary", "Equipment List"].enumerated() {
            let url = paperwork.appendingPathComponent("\(name).pdf")
            pdf(url, title: name, pages: 1 + i % 3, accent: i + 2)
            stamp(url)
        }
        text(paperwork.appendingPathComponent("Meeting Notes.txt"), "Monday planning\n\n- Website launch moved to the 14th\n- Photos due Friday\n- Next meeting: Thursday, 10:00\n")
        text(paperwork.appendingPathComponent("Reading List.md"), "# Reading list\n\n- The Shipping Forecast\n- A Field Guide to Getting Lost\n- How Buildings Learn\n")
        standIn(paperwork.appendingPathComponent("Budget 2026.xlsx"), megabytes: 0.34)
        standIn(paperwork.appendingPathComponent("Proposal.docx"), megabytes: 1.2)
        standIn(paperwork.appendingPathComponent("Archive 2025.zip"), megabytes: 96.4)

        // A few tags, so the dots show.
        let tags: [(String, [String])] = [
            ("Photos/Glacier Lake.jpg", ["Blue"]), ("Photos/Harbor Lights.jpg", ["Orange"]), ("Photos/Wildflower Meadow.jpg", ["Green"]),
            ("Projects/Quarterly Report Q3.pdf", ["Red"]), ("Projects/Harbor Website", ["Blue"]), ("Projects/Annual Report 2026", ["Orange"]),
            ("Projects/Harbor Website/Style Guide.pdf", ["Green"]), ("Paperwork/Invoice 1043.pdf", ["Red"]),
        ]
        for (path, names) in tags { _ = Tags.write(names, to: root.appendingPathComponent(path)) }
    }

    // MARK: Drawing

    private static func context(_ size: CGSize) -> CGContext {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func writeImage(_ image: CGImage, to url: URL, type: UTType) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private static func color(_ hue: Double, _ saturation: Double, _ brightness: Double) -> CGColor {
        NSColor(calibratedHue: CGFloat(hue - floor(hue)), saturation: CGFloat(saturation), brightness: CGFloat(brightness), alpha: 1).cgColor
    }

    /// A simple landscape: a sky, a sun or moon, and layers of hills. Each seed gives another one.
    static func landscape(seed: Int, size: CGSize) -> CGImage {
        let cg = context(size)
        var state = UInt64(seed &* 2_654_435_761 &+ 12_345) | 1
        func random() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 10_000) / 10_000
        }
        let hue = random()
        let night = seed % 5 == 3
        let sky = [color(hue, night ? 0.75 : 0.45, night ? 0.25 : 0.95), color(hue + 0.08, night ? 0.6 : 0.30, night ? 0.45 : 1.0), color(hue + 0.55, 0.35, night ? 0.55 : 1.0)]
        let gradient = CGGradient(colorsSpace: nil, colors: sky as CFArray, locations: [0, 0.55, 1])!
        cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: size.height * 0.25), options: [.drawsAfterEndLocation])
        let sun = CGPoint(x: size.width * (0.2 + 0.6 * random()), y: size.height * (0.55 + 0.25 * random()))
        let radius = size.height * (0.05 + 0.05 * random())
        cg.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.18).cgColor)
        cg.fillEllipse(in: CGRect(x: sun.x - radius * 2.2, y: sun.y - radius * 2.2, width: radius * 4.4, height: radius * 4.4))
        cg.setFillColor(NSColor(calibratedWhite: 1, alpha: night ? 0.9 : 0.85).cgColor)
        cg.fillEllipse(in: CGRect(x: sun.x - radius, y: sun.y - radius, width: radius * 2, height: radius * 2))
        let layers = 4
        for layer in 0..<layers {
            let depth = Double(layer) / Double(layers - 1)
            let base = size.height * (0.50 - 0.38 * depth)
            let height = size.height * (0.16 - 0.06 * depth)
            let a = 1.5 + random() * 2.5, b = 3 + random() * 4, p = random() * 6, q = random() * 6
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            var x = 0.0
            while x <= size.width {
                let t = x / size.width
                let y = base + height * (0.6 * sin(t * a * .pi + p) + 0.4 * sin(t * b * .pi + q))
                path.addLine(to: CGPoint(x: x, y: y))
                x += 8
            }
            path.addLine(to: CGPoint(x: size.width, y: 0))
            path.closeSubpath()
            cg.addPath(path)
            cg.setFillColor(color(hue + 0.5 + 0.05 * depth, 0.25 + 0.35 * depth, (night ? 0.45 : 0.75) - 0.5 * depth))
            cg.fillPath()
        }
        return cg.makeImage()!
    }

    /// A wireframe-style page design: a header, a picture block, and cards.
    static func mockup(seed: Int) -> CGImage {
        let size = CGSize(width: 1440, height: 1024)
        let cg = context(size)
        let hue = Double(seed) * 0.137
        cg.setFillColor(NSColor(calibratedWhite: 0.97, alpha: 1).cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        cg.setFillColor(color(hue, 0.55, 0.55))
        cg.fill(CGRect(x: 0, y: size.height - 90, width: size.width, height: 90))
        cg.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.85).cgColor)
        for i in 0..<4 { cg.fill(CGRect(x: 900 + Double(i) * 120, y: size.height - 55, width: 80, height: 16)) }
        cg.draw(landscape(seed: seed + 30, size: CGSize(width: 1200, height: 420)), in: CGRect(x: 120, y: 470, width: 1200, height: 420))
        for i in 0..<3 {
            let card = CGRect(x: 120 + Double(i) * 410, y: 110, width: 380, height: 300)
            cg.setFillColor(NSColor.white.cgColor)
            cg.addPath(CGPath(roundedRect: card, cornerWidth: 18, cornerHeight: 18, transform: nil))
            cg.fillPath()
            cg.setFillColor(color(hue + Double(i) * 0.09, 0.35, 0.85))
            cg.addPath(CGPath(roundedRect: CGRect(x: card.minX + 24, y: card.maxY - 110, width: 86, height: 86), cornerWidth: 14, cornerHeight: 14, transform: nil))
            cg.fillPath()
            cg.setFillColor(NSColor(calibratedWhite: 0.82, alpha: 1).cgColor)
            for line in 0..<4 { cg.fill(CGRect(x: card.minX + 24, y: card.minY + 40 + Double(line) * 30, width: line == 0 ? 180 : 320, height: 12)) }
        }
        return cg.makeImage()!
    }

    /// A document that looks written: a colored band, a title, and paragraphs as gray lines.
    static func pdf(_ url: URL, title: String, pages: Int, accent: Int) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let cg = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for page in 0..<pages {
            cg.beginPDFPage(nil)
            cg.setFillColor(NSColor.white.cgColor)
            cg.fill(box)
            if page == 0 {
                cg.setFillColor(color(Double(accent) * 0.17 + 0.55, 0.55, 0.62))
                cg.fill(CGRect(x: 0, y: 640, width: 612, height: 152))
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white,
                ]))
                cg.textPosition = CGPoint(x: 54, y: 690)
                CTLineDraw(line, cg)
            }
            cg.setFillColor(NSColor(calibratedWhite: 0.80, alpha: 1).cgColor)
            var y = page == 0 ? 590.0 : 720.0
            var n = page * 7
            while y > 70 {
                n += 1
                let gap = n % 6 == 0
                if !gap { cg.fill(CGRect(x: 54, y: y, width: n % 6 == 5 ? 260 : 504, height: 7)) }
                y -= gap ? 26 : 17
            }
            cg.endPDFPage()
        }
        cg.closePDF()
    }
}
#endif
