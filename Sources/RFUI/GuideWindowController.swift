import AppKit
import WebKit

/// The user guide, in its own window. Its search field searches only the guide, unlike the system
/// Help menu's search, which mixes in unrelated results.
@MainActor
public final class GuideWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    public static let shared = GuideWindowController()

    /// Sections of guide.html that other parts of the app link to.
    public enum Section: String {
        case top = "", start, views, sorting, settings, prefs, search, syntax, kinds, files, ops, tags, keys, access, coming
    }

    private let webView = WKWebView()
    private var searchItem: NSSearchToolbarItem?
    private static let searchID = NSToolbarItem.Identifier("guideSearch")

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "RealFinder Guide"
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("RealFinderGuide")
        super.init(window: window)
        window.contentView = webView
        let toolbar = NSToolbar(identifier: "RealFinder.guide")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError() }

    public static var guideURL: URL? { Bundle.module.url(forResource: "guide", withExtension: "html", subdirectory: "Guide") }

    public func show(_ section: Section = .top) {
        guard let url = Self.guideURL else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.fragment = section.rawValue.isEmpty ? nil : section.rawValue
        if webView.url?.path == url.path, !section.rawValue.isEmpty {
            webView.evaluateJavaScript("document.getElementById('\(section.rawValue)')?.scrollIntoView()")
        } else {
            webView.loadFileURL(components.url!, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Toolbar search: finds within the guide only

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.searchID] }
    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.searchID] }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.searchID else { return nil }
        let item = NSSearchToolbarItem(itemIdentifier: id)
        item.searchField.placeholderString = "Search the Guide"
        item.searchField.delegate = self
        item.searchField.target = self
        item.searchField.action = #selector(searchChanged(_:))
        item.preferredWidthForSearchField = 240
        searchItem = item
        return item
    }

    @objc private func searchChanged(_ field: NSSearchField) { find(field.stringValue, backwards: false) }

    /// Return finds the next match, Shift-Return the previous one.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), let field = control as? NSSearchField else { return false }
        find(field.stringValue, backwards: NSEvent.modifierFlags.contains(.shift))
        return true
    }

    private func find(_ text: String, backwards: Bool) {
        guard !text.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        webView.find(text, configuration: config) { result in
            if !result.matchFound { NSSound.beep() }
        }
    }
}
