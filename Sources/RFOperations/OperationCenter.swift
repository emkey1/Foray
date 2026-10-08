import Foundation
import RFFileSystem
import Synchronization

/// One submitted operation, observed by the UI.
@MainActor
public final class Job: Identifiable {
    public let id = UUID()
    public let request: OperationRequest
    public let control = JobControl()
    public internal(set) var progress = JobProgress()
    public internal(set) var result: OperationResult?
    /// True for undo/redo steps (no undo of their own beyond the redo the center registers).
    public let isUndoStep: Bool
    let sharedProgress = ProgressBox()

    init(_ request: OperationRequest, isUndoStep: Bool) {
        self.request = request
        self.isUndoStep = isUndoStep
    }

    public var title: String { request.title }
    public var isFinished: Bool { result != nil }
}

/// Runs file operations (DESIGN.md §5.7): one app-wide queue, one app-wide undo stack (like
/// Finder), progress for the UI, conflict questions answered by the UI.
@MainActor
public final class OperationCenter {
    public static let shared = OperationCenter(journal: .shared, trash: Trash.system)

    public let undoManager = UndoManager()
    public private(set) var jobs: [Job] = []
    public var activeJobs: [Job] { jobs.filter { !$0.isFinished } }

    /// Asked when an item already exists at the destination. Default: Keep Both (never destructive).
    public var resolveConflict: @MainActor (Job, ConflictQuestion) async -> ConflictAnswer = { _, _ in ConflictAnswer(.keepBoth) }
    /// Told when a job ends with errors (or stops).
    public var reportProblems: @MainActor (Job, OperationResult) -> Void = { _, _ in }

    private let journal: OperationJournal
    private let trash: TrashFunction
    private var observers: [UUID: @MainActor (Event) -> Void] = [:]
    private var ticker: Timer?

    public enum Event {
        case progress
        case finished(Job, OperationResult)
    }

    public init(journal: OperationJournal, trash: @escaping TrashFunction) {
        self.journal = journal
        self.trash = trash
        undoManager.levelsOfUndo = 50
    }

    public func observe(_ handler: @escaping @MainActor (Event) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    private func emit(_ event: Event) { for o in observers.values { o(event) } }

    /// Starts an operation. The returned job's result arrives via `.finished` (or `run`).
    @discardableResult
    public func submit(_ request: OperationRequest) -> Job {
        let job = Job(request, isUndoStep: false)
        start(job)
        return job
    }

    /// Runs an operation to completion (tests and callers that need the result).
    public func run(_ request: OperationRequest) async -> OperationResult {
        let job = submit(request)
        return await finished(job)
    }

    func finished(_ job: Job) async -> OperationResult {
        while job.result == nil { try? await Task.sleep(for: .milliseconds(10)) }
        return job.result!
    }

    private func start(_ job: Job) {
        jobs.append(job)
        startTicker()
        let execution = Execution(job.request, control: job.control, progress: job.sharedProgress, journal: journal, trash: trash) {
            [weak self, weak job] question in
            await self?.ask(job, question) ?? ConflictAnswer(.skip)
        }
        Task.detached(priority: .userInitiated) {
            let result = await execution.run()
            await MainActor.run { self.complete(job, result) }
        }
    }

    private func ask(_ job: Job?, _ question: ConflictQuestion) async -> ConflictAnswer {
        guard let job else { return ConflictAnswer(.skip) }
        return await resolveConflict(job, question)
    }

    private func complete(_ job: Job, _ result: OperationResult) {
        job.progress = job.sharedProgress.current
        job.result = result
        if !job.isUndoStep { registerUndo(for: job.request, result: result) }
        if !result.errors.isEmpty || result.stopped { reportProblems(job, result) }
        emit(.finished(job, result))
        // Keep finished jobs briefly for the progress list, then drop them.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.jobs.removeAll { $0 === job }
            self.emit(.progress)
        }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                for job in self.jobs where !job.isFinished { job.progress = job.sharedProgress.current }
                self.emit(.progress)
                if self.activeJobs.isEmpty {
                    self.ticker?.invalidate()
                    self.ticker = nil
                }
            }
        }
    }

    // MARK: Undo (DESIGN.md §5.7)

    /// Undo runs the steps that revert a result; the steps' combined result is reverted for redo.
    private func registerUndo(for request: OperationRequest, result: OperationResult) {
        guard case .delete = request else {
            guard let steps = result.revert() else { return }
            register(steps, name: request.undoName)
            return
        }
    }

    private func register(_ steps: [OperationRequest], name: String) {
        undoManager.registerUndo(withTarget: self) { center in
            MainActor.assumeIsolated { center.perform(steps, name: name) }
        }
        undoManager.setActionName(name)
    }

    private func perform(_ steps: [OperationRequest], name: String) {
        // Registering inside an undo makes it the redo (and vice versa); do it synchronously, then
        // run the steps and record their actual results for the next undo/redo.
        let holder = UndoHolder()
        undoManager.registerUndo(withTarget: self) { center in
            MainActor.assumeIsolated {
                guard let steps = holder.next else { return }
                center.perform(steps, name: name)
            }
        }
        undoManager.setActionName(name)
        Task { @MainActor in
            var combined = OperationResult()
            for step in steps {
                let job = Job(step, isUndoStep: true)
                start(job)
                let r = await finished(job)
                combined.log += r.log
                combined.errors += r.errors
                combined.changedFolders.formUnion(r.changedFolders)
            }
            holder.next = combined.revert()
        }
    }

    /// Removes temporary copies left by a crash or a kill. Call once at launch.
    public func recoverInterruptedOperations() { journal.recover() }
}

@MainActor
private final class UndoHolder {
    var next: [OperationRequest]?
}
