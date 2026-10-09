import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Finder's Quick Actions (DESIGN.md §4.2): rotate images and PDFs, combine into a PDF.
public enum QuickActions {
    // EXIF orientation after a quarter turn (derived from the orientation definitions).
    static let clockwise: [Int: Int] = [1: 6, 2: 7, 3: 8, 4: 5, 5: 2, 6: 3, 7: 4, 8: 1]
    static let counterclockwise: [Int: Int] = [1: 8, 2: 5, 3: 6, 4: 7, 5: 4, 6: 1, 7: 2, 8: 3]

    public static func canRotate(_ type: UTType) -> Bool {
        type.conforms(to: .pdf) || (type.conforms(to: .image) && !type.conforms(to: .svg) && !type.conforms(to: .ico))
    }

    public static func canCombineIntoPDF(_ type: UTType) -> Bool {
        type.conforms(to: .pdf) || (type.conforms(to: .image) && !type.conforms(to: .svg))
    }

    public struct Failure: Error { public let code: Int32 }

    /// Rotates a quarter turn. Images get a new orientation tag where the format allows it (no
    /// re-compression, so photos don't lose quality); PDFs rotate every page.
    public static func rotate(_ url: URL, clockwise cw: Bool) throws {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).rfrotate-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: temp) }
        if type.conforms(to: .pdf) {
            guard let doc = PDFDocument(url: url) else { throw Failure(code: EINVAL) }
            for i in 0..<doc.pageCount { if let page = doc.page(at: i) { page.rotation = (page.rotation + (cw ? 90 : 270)) % 360 } }
            guard doc.write(to: temp) else { throw Failure(code: EIO) }
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let uti = CGImageSourceGetType(source) else {
                throw Failure(code: EINVAL)
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let old = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let new = (cw ? clockwise : counterclockwise)[old] ?? 1
            guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, uti, 1, nil) else { throw Failure(code: EIO) }
            // Lossless: copy the image data, change only the orientation (JPEG, HEIC, TIFF, PNG…).
            let options: [CFString: Any] = [kCGImageDestinationOrientation: new, kCGImageDestinationMergeMetadata: true]
            var error: Unmanaged<CFError>?
            if !CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) {
                // Formats that can't carry an orientation: redraw the pixels turned.
                try redraw(source, type: uti, to: temp, clockwise: cw)
            }
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    private static func redraw(_ source: CGImageSource, type: CFString, to temp: URL, clockwise cw: Bool) throws {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(code: EINVAL) }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(code: EIO) }
        if cw {
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let turned = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) else { throw Failure(code: EIO) }
        CGImageDestinationAddImage(dest, turned, CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        guard CGImageDestinationFinalize(dest) else { throw Failure(code: EIO) }
    }

    /// One PDF page showing the image at its size, drawn by hand: `PDFPage(image:)` raises an
    /// Objective-C exception (a crash) on images it can't use.
    static func imagePage(_ url: URL) -> PDFPage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              image.width > 0, image.height > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let turned = [5, 6, 7, 8].contains(orientation)
        var box = CGRect(x: 0, y: 0, width: turned ? image.height : image.width, height: turned ? image.width : image.height)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        // Respect the photo's orientation, as Finder does.
        switch orientation {
        case 3: ctx.translateBy(x: box.width, y: box.height); ctx.rotate(by: .pi)
        case 6: ctx.translateBy(x: 0, y: box.height); ctx.rotate(by: -.pi / 2)
        case 8: ctx.translateBy(x: box.width, y: 0); ctx.rotate(by: .pi / 2)
        default: break
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    /// Combines images and PDFs, in order, into one PDF at `destination`.
    public static func createPDF(from items: [URL], at destination: URL) throws {
        let doc = PDFDocument()
        for url in items {
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            if type.conforms(to: .pdf), let pdf = PDFDocument(url: url) {
                for i in 0..<pdf.pageCount { if let page = pdf.page(at: i) { doc.insert(page, at: doc.pageCount) } }
            } else if let page = imagePage(url) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        guard doc.pageCount > 0 else { throw Failure(code: EINVAL) }
        guard doc.write(to: destination) else { throw Failure(code: EIO) }
    }
}
