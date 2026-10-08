import AppKit
import RFOperations

/// The toolbar's operations button: a spinner while file operations run; click for the list.
@MainActor
final class JobsToolbarButton: NSButton {
    private let spinner = NSProgressIndicator()
    private var observer: UUID?
    private let popover = NSPopover()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        bezelStyle = .toolbar
        image = NSImage(systemSymbolName: "arrow.left.arrow.right.circle", accessibilityDescription: "File operations")
        imagePosition = .imageOnly
        toolTip = "File operations"
        target = self
        action = #selector(showJobs)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        popover.behavior = .transient
        popover.contentViewController = JobsViewController()
        observer = OperationCenter.shared.observe { [weak self] _ in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        let active = !OperationCenter.shared.activeJobs.isEmpty
        isHidden = OperationCenter.shared.jobs.isEmpty
        if active {
            spinner.startAnimation(nil)
            image = nil
        } else {
            spinner.stopAnimation(nil)
            image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "File operations done")
        }
        (popover.contentViewController as? JobsViewController)?.reload()
    }

    @objc private func showJobs() {
        (popover.contentViewController as? JobsViewController)?.reload()
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }
}

/// The list of running and just-finished operations.
@MainActor
final class JobsViewController: NSViewController {
    private let stack = NSStackView()
    private var rows: [UUID: JobRow] = [:]

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.widthAnchor.constraint(equalToConstant: 380).isActive = true
        view = stack
    }

    func reload() {
        _ = view
        let jobs = OperationCenter.shared.jobs
        for (id, row) in rows where !jobs.contains(where: { $0.id == id }) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        for job in jobs {
            let row = rows[job.id] ?? {
                let r = JobRow(job)
                rows[job.id] = r
                stack.addArrangedSubview(r)
                r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
                return r
            }()
            row.update()
        }
        if jobs.isEmpty && stack.arrangedSubviews.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: "No file operations"))
        } else if !jobs.isEmpty {
            stack.arrangedSubviews.filter { $0 is NSTextField }.forEach { $0.removeFromSuperview() }
        }
    }
}

@MainActor
private final class JobRow: NSView {
    let job: Job
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let pause = NSButton()
    private let cancel = NSButton()

    init(_ job: Job) {
        self.job = job
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        for (button, symbol, tip, action) in [(pause, "pause.circle", "Pause", #selector(togglePause)),
                                              (cancel, "xmark.circle.fill", "Stop", #selector(stop))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.isBordered = false
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        for v in [title, detail, bar, pause, cancel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: pause.leadingAnchor, constant: -6),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: pause.leadingAnchor, constant: -6),
            detail.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor),
            cancel.trailingAnchor.constraint(equalTo: trailingAnchor),
            cancel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            pause.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -4),
            pause.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update() {
        let p = job.progress
        title.stringValue = job.title
        if let fraction = p.fraction {
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        let bytes = ByteCountFormatter()
        switch (job.result, p.phase) {
        case (let r?, _):
            bar.doubleValue = 1
            detail.stringValue = r.errors.isEmpty ? (r.stopped || job.control.isCancelled ? "Stopped" : "Done")
                : "Done, \(r.errors.count) couldn't be processed"
        case (nil, .preparing): detail.stringValue = "Preparing…"
        case (nil, .waitingForAnswer): detail.stringValue = "Waiting for your answer"
        case (nil, _) where job.control.isPaused: detail.stringValue = "Paused"
        default:
            var s = p.currentName
            if p.bytesTotal > 0 {
                s += " — \(bytes.string(fromByteCount: p.bytesDone)) of \(bytes.string(fromByteCount: p.bytesTotal))"
            } else if p.itemsTotal > 1 {
                s += " — \(p.itemsDone) of \(p.itemsTotal)"
            }
            detail.stringValue = s
        }
        pause.isHidden = job.isFinished
        cancel.isHidden = job.isFinished
        pause.image = NSImage(systemSymbolName: job.control.isPaused ? "play.circle" : "pause.circle", accessibilityDescription: nil)
        pause.toolTip = job.control.isPaused ? "Resume" : "Pause"
    }

    @objc private func togglePause() {
        if job.control.isPaused { job.control.resume() } else { job.control.pause() }
        update()
    }

    @objc private func stop() {
        job.control.cancel()
        update()
    }
}
