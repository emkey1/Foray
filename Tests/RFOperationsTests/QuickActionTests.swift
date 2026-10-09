import AppKit
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations

@MainActor
@Suite struct QuickActionTests {
    /// A 40×20 image in the given format.
    func makeImage(_ url: URL, type: UTType) {
        let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }

    func info(_ url: URL) -> (w: Int, h: Int, orientation: Int) {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        return ((p[kCGImagePropertyPixelWidth] as! NSNumber).intValue, (p[kCGImagePropertyPixelHeight] as! NSNumber).intValue,
                (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
    }

    @Test func jpegRotatesLosslesslyAndUndoes() async throws {
        let s = try Sandbox()
        let jpg = s.work.appendingPathComponent("photo.jpg")
        makeImage(jpg, type: .jpeg)
        let pixelsBefore = try Data(contentsOf: jpg).count
        let r = await s.run(.rotate([jpg], clockwise: true))
        #expect(r.errors.isEmpty)
        let after = info(jpg)
        #expect(after.w == 40 && after.h == 20 && after.orientation == 6)   // same pixels, new orientation tag
        #expect(abs(try Data(contentsOf: jpg).count - pixelsBefore) < 200)   // not re-compressed
        #expect(s.center.undoManager.undoActionName == "Rotate Right")
        await s.undo()
        #expect(info(jpg).orientation == 1)
        _ = await s.run(.rotate([jpg], clockwise: false))
        #expect(info(jpg).orientation == 8)
    }

    @Test func formatsWithoutOrientationAreRedrawn() async throws {
        let s = try Sandbox()
        let bmp = s.work.appendingPathComponent("old.bmp")
        makeImage(bmp, type: .bmp)
        let r = await s.run(.rotate([bmp], clockwise: true))
        #expect(r.errors.isEmpty)
        let i = info(bmp)
        #expect((i.w == 20 && i.h == 40) || i.orientation == 6)
    }

    @Test func pdfPagesRotate() async throws {
        let s = try Sandbox()
        let pdf = s.work.appendingPathComponent("doc.pdf")
        let png = s.work.appendingPathComponent("page.png")
        makeImage(png, type: .png)
        try QuickActions.createPDF(from: [png], at: pdf)
        _ = await s.run(.rotate([pdf], clockwise: true))
        #expect(PDFDocument(url: pdf)?.page(at: 0)?.rotation == 90)
        await s.undo()
        #expect(PDFDocument(url: pdf)?.page(at: 0)?.rotation == 0)
    }

    @Test func createPDFCombinesInOrder() async throws {
        let s = try Sandbox()
        let a = s.work.appendingPathComponent("a.png"), b = s.work.appendingPathComponent("b.jpg")
        makeImage(a, type: .png)
        makeImage(b, type: .jpeg)
        let pdf = s.work.appendingPathComponent("two.pdf")
        try QuickActions.createPDF(from: [a, b], at: pdf)   // a 2-page PDF to include
        let r = await s.run(.createPDF([a, b, pdf]))
        let out = try #require(r.created.first)
        #expect(out.lastPathComponent == "a.pdf")
        #expect(PDFDocument(url: out)?.pageCount == 4)
        #expect(await s.run(.createPDF([a])).created.first?.lastPathComponent == "a 2.pdf")
        await s.undo()
        #expect(!s.exists("a 2.pdf"))
        // Unreadable "images" are skipped, never a crash.
        let junk = s.file("junk.png", "not an image")
        #expect(throws: QuickActions.Failure.self) { try QuickActions.createPDF(from: [junk], at: s.work.appendingPathComponent("j.pdf")) }
        #expect(QuickActions.canRotate(.jpeg) && QuickActions.canRotate(.pdf) && !QuickActions.canRotate(.plainText))
    }
}
