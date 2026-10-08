import AppKit
import RFModel
import RFOperations

/// Files on the pasteboard. Cut (I1, DESIGN.md §3.4) writes the URLs plus a private marker; Paste
/// then moves instead of copying. Finder ignores the marker, so pasting there copies.
@MainActor
enum FileClipboard {
    static let cutMarker = NSPasteboard.PasteboardType("local.realfinder.cut")
    private static var cutChangeCount: Int?
    private static var cutPaths: Set<String> = []

    static func write(_ urls: [URL], cut: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        // Plain-text paths too, for pasting into Terminal or a text editor.
        pb.addTypes([.string], owner: nil)
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        if cut {
            pb.addTypes([cutMarker], owner: nil)
            pb.setString("cut", forType: cutMarker)
            cutChangeCount = pb.changeCount
            cutPaths = Set(urls.map(\.standardizedFileURL.path))
        } else {
            clearCut()
        }
    }

    /// File URLs on the pasteboard (from RealFinder, Finder or any app), and whether they were cut here.
    static func read() -> (urls: [URL], isCut: Bool)? {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        let cut = pb.changeCount == cutChangeCount && pb.string(forType: cutMarker) != nil
        return (urls, cut)
    }

    static var hasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Cut items show dimmed until they're pasted or the clipboard changes.
    static func isCut(_ url: URL) -> Bool {
        guard let count = cutChangeCount, NSPasteboard.general.changeCount == count else { return false }
        return cutPaths.contains(url.standardizedFileURL.path)
    }

    static func clearCut() {
        cutChangeCount = nil
        cutPaths = []
    }
}

/// Connects the operation engine to the windows: conflict questions, problem reports, refreshing
/// tabs and selecting results.
@MainActor
final class FileOperationsUI {
    static let shared = FileOperationsUI()

    /// The tab that started each job, so it can select the results.
    private var origins: [UUID: WeakState] = [:]
    /// Called with the tab and resulting URLs after jobs that want follow-up (e.g. rename a new folder).
    private var completions: [UUID: @MainActor (OperationResult) -> Void] = [:]
    private var observer: UUID?
    private weak var installedOn: OperationCenter?

    private final class WeakState {
        weak var state: BrowserState?
        init(_ s: BrowserState) { state = s }
    }

    func install() {
        let center = OperationCenter.shared
        guard installedOn !== center else { return }
        installedOn = center
        center.resolveConflict = { [weak self] job, question in await self?.ask(question, job: job) ?? ConflictAnswer(.skip) }
        center.reportProblems = { [weak self] job, result in self?.report(job, result) }
        observer = center.observe { [weak self] event in
            guard case .finished(let job, let result) = event else { return }
            self?.finished(job, result)
        }
        center.recoverInterruptedOperations()
    }

    @discardableResult
    func submit(_ request: OperationRequest, from state: BrowserState?, then: (@MainActor (OperationResult) -> Void)? = nil) -> Job {
        install()
        let job = OperationCenter.shared.submit(request)
        if let state { origins[job.id] = WeakState(state) }
        if let then { completions[job.id] = then }
        return job
    }

    private func finished(_ job: Job, _ result: OperationResult) {
        let origin = origins.removeValue(forKey: job.id)?.state
        for state in BrowserState.live {
            state.applyFileChanges(result, select: state === origin ? result.resultingItems : [])
        }
        completions.removeValue(forKey: job.id)?(result)
    }

    // MARK: Conflicts

    private func ask(_ q: ConflictQuestion, job: Job) async -> ConflictAnswer {
        let alert = NSAlert()
        let folder = q.existing.deletingLastPathComponent().lastPathComponent
        alert.messageText = "An item named “\(q.existing.lastPathComponent)” already exists in “\(folder)”."
        var info = "Replace moves the existing item to the Trash, so you can undo it."
        if q.incomingIsFolder != q.existingIsFolder {
            info = "The existing item is a \(q.existingIsFolder ? "folder" : "file"); the one you're adding is a \(q.incomingIsFolder ? "folder" : "file"). " + info
        }
        if let a = q.incomingModified, let b = q.existingModified, a != b {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            info += "\n\nYours: modified \(f.string(from: a)).\nExisting: modified \(f.string(from: b))."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Keep Both")   // first = default (Return): never destructive
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Stop")
        alert.showsSuppressionButton = q.moreToCome
        alert.suppressionButton?.title = "Apply to all"
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
        } else {
            response = alert.runModal()
        }
        let all = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return ConflictAnswer(.keepBoth, applyToAll: all)
        case .alertSecondButtonReturn: return ConflictAnswer(.replace, applyToAll: all)
        case .alertThirdButtonReturn: return ConflictAnswer(.skip, applyToAll: all)
        default: return ConflictAnswer(.stop)
        }
    }

    // MARK: Problems

    private func report(_ job: Job, _ result: OperationResult) {
        guard !result.errors.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let n = result.errors.count
        alert.messageText = n == 1 ? "1 item couldn't be processed" : "\(n) items couldn't be processed"
        let lines = result.errors.prefix(10).map(\.message)
        alert.informativeText = job.title + ".\n\n" + lines.joined(separator: "\n") + (n > 10 ? "\n…and \(n - 10) more." : "")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
