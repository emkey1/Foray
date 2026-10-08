import AppKit
import RFModel

/// Shown below the toolbar while a search is active (DESIGN.md §3.1):
///   Search: [ Projects | This Mac ]  [x] Subfolders  [Names v]
///   [Folders] [Documents] [Images] … (kind chips; selecting several matches any of them)
@MainActor
final class SearchScopeBar: NSView {
    var onChange: (((inout SearchQuery) -> Void) -> Void)?

    private let scope = NSSegmentedControl(labels: ["Folder", "This Mac"], trackingMode: .selectOne, target: nil, action: nil)
    private let subfolders = NSButton(checkboxWithTitle: "Subfolders", target: nil, action: nil)
    private let match = NSPopUpButton()
    private let chips: NSSegmentedControl
    private let categories = KindCatalog.shared.categories
    private var query: SearchQuery?

    override init(frame: NSRect) {
        chips = NSSegmentedControl(labels: categories.map(\.name), trackingMode: .selectAny, target: nil, action: nil)
        super.init(frame: frame)
        for (i, c) in categories.enumerated() {
            chips.setImage(NSImage(systemSymbolName: c.symbol, accessibilityDescription: nil), forSegment: i)
            chips.setImageScaling(.scaleProportionallyDown, forSegment: i)
            chips.setToolTip("Only \(c.name.lowercased()) (kind:\(c.id))", forSegment: i)
        }
        let label = NSTextField(labelWithString: "Search:")
        label.textColor = .secondaryLabelColor
        for control in [scope, chips] as [NSSegmentedControl] { control.controlSize = .small; control.target = self }
        scope.action = #selector(scopeChanged)
        chips.action = #selector(chipsChanged)
        subfolders.controlSize = .small
        subfolders.target = self
        subfolders.action = #selector(subfoldersChanged)
        subfolders.toolTip = "Off: only filter the items directly in this folder"
        match.controlSize = .small
        match.addItems(withTitles: ["Names", "Names & Contents"])
        match.target = self
        match.action = #selector(matchChanged)

        let top = NSStackView(views: [label, scope, subfolders, match])
        top.spacing = 10
        let all = NSStackView(views: [top, chips])
        all.orientation = .vertical
        all.alignment = .leading
        all.spacing = 6
        all.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 8, right: 12)
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            all.topAnchor.constraint(equalTo: topAnchor),
            all.leadingAnchor.constraint(equalTo: leadingAnchor),
            all.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            all.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ q: SearchQuery) {
        query = q
        let originName = q.origin.map { FileManager.default.displayName(atPath: $0.path) } ?? "Folder"
        scope.setLabel("“\(originName)”", forSegment: 0)
        scope.setEnabled(q.origin != nil, forSegment: 0)
        scope.selectedSegment = q.scope == .thisMac ? 1 : 0
        if case .folder(_, let recursive) = q.scope {
            subfolders.state = recursive ? .on : .off
            subfolders.isEnabled = true
        } else {
            subfolders.state = .on
            subfolders.isEnabled = false
        }
        match.selectItem(at: q.match == .names ? 0 : 1)
        let kinds = q.kinds
        for (i, c) in categories.enumerated() { chips.setSelected(kinds.contains(c.id), forSegment: i) }
    }

    @objc private func scopeChanged() {
        let thisMac = scope.selectedSegment == 1
        onChange? { q in
            if thisMac { q.scope = .thisMac } else if let origin = q.origin { q.scope = .folder(origin, recursive: true) }
        }
    }

    @objc private func subfoldersChanged() {
        let on = subfolders.state == .on
        onChange? { q in if let url = q.scope.folderURL { q.scope = .folder(url, recursive: on) } }
    }

    @objc private func matchChanged() {
        let mode: MatchMode = match.indexOfSelectedItem == 0 ? .names : .namesAndContents
        onChange? { $0.match = mode }
    }

    @objc private func chipsChanged() {
        var ids = Set<KindCategory.ID>()
        for (i, c) in categories.enumerated() where chips.isSelected(forSegment: i) { ids.insert(c.id) }
        onChange? { q in q = q.settingKinds(ids) }
    }
}
