import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFOperations
@testable import RFUI

/// A stand-in for a real drag carrying file URLs.
final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let mask: NSDragOperation
    let sequence: Int

    init(_ urls: [URL], mask: NSDragOperation = .every) {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("rf-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        self.mask = mask
        sequence = Int.random(in: 1...Int(Int32.max))
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { sequence }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class DragAndDropTests {
        let base = TestDirs.make("dnd")
        let a: URL, b: URL

        deinit { try? FileManager.default.removeItem(at: base) }

        init() throws {
            a = base.appendingPathComponent("A", isDirectory: true)
            b = base.appendingPathComponent("B", isDirectory: true)
            for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            FileManager.default.createFile(atPath: a.appendingPathComponent("doc.txt").path, contents: nil)
            let trash = base.appendingPathComponent("Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            OperationCenter.shared = OperationCenter(journal: OperationJournal(store: AppSupportStore(directory: base.appendingPathComponent("j"))),
                                                     trash: { url in
                let dest = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            })
            FileOperationsUI.shared.install()
        }

        @Test func rules() {
            let doc = a.appendingPathComponent("doc.txt")
            #expect(DragAndDrop.operation(FakeDrag([doc]), to: b) == .move)           // same disk: move
            #expect(DragAndDrop.operation(FakeDrag([doc]), to: a) == [])              // already there
            #expect(DragAndDrop.operation(FakeDrag([a]), to: a) == [])                // onto itself
            let inner = a.appendingPathComponent("inner")
            try? FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            #expect(DragAndDrop.operation(FakeDrag([a]), to: inner) == [])            // into its own subfolder
            #expect(DragAndDrop.operation(FakeDrag([doc], mask: .copy), to: b) == .copy)  // source only allows copying
            #expect(DragAndDrop.operation(FakeDrag([]), to: b) == [])
        }

        @Test func dropMovesTheFile() async {
            #expect(DragAndDrop.perform(FakeDrag([a.appendingPathComponent("doc.txt")]), to: b, from: nil))
            let deadline = Date().addingTimeInterval(10)
            while FileManager.default.fileExists(atPath: a.appendingPathComponent("doc.txt").path) && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("doc.txt").path))
        }

        @Test func dockTrashDragMovesToTrash() async {
            let doc = a.appendingPathComponent("doc.txt")
            DragAndDrop.draggingEnded(.delete, items: [doc], state: nil)
            let deadline = Date().addingTimeInterval(10)
            while FileManager.default.fileExists(atPath: doc.path) && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            #expect(!FileManager.default.fileExists(atPath: doc.path))
            #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("Trash/doc.txt").path))
        }
    }
}
