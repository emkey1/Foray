import AppKit
import RFModel

/// Foray's desktop (DESIGN.md Q3, "Use Foray instead of Finder"): the Desktop folder's icons drawn
/// over the wallpaper, behind every window, on every Space. Everything works as in a Foray window
/// (open, rename, drag, Quick Look, Get Info, its menus); going to another folder opens a window.
@MainActor
public final class DesktopWindowController: NSWindowController, NSWindowDelegate {
    public private(set) static var shared: DesktopWindowController?
    let browser: BrowserViewController
    private var observers: [NSObjectProtocol] = []

    public static func show() {
        if shared == nil { shared = DesktopWindowController() }
        shared?.place()
        shared?.window?.orderBack(nil)
    }

    public static func hide() {
        shared?.browser.state.invalidate()
        shared?.window?.orderOut(nil)
        shared = nil
    }

    static var isShown: Bool { shared != nil }

    init(folder: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]) {
        browser = BrowserViewController(location: .folder(folder), isDesktop: true)
        let window = DesktopWindow(contentRect: NSScreen.main?.visibleFrame ?? .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.title = "Desktop"
        super.init(window: window)
        window.delegate = self
        window.contentViewController = browser
        browser.state.openElsewhere = { location, names in WindowManager.shared.open(location, select: names) }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The main screen's usable area, so icons stay clear of the menu bar and the Dock.
    func place() {
        guard let frame = NSScreen.main?.visibleFrame, let window else { return }
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool { false }
}

/// A borderless window that can still take keyboard focus (for renaming, ⌘⌫ and so on).
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) { NSSound.beep() }   // ⌘W never closes the desktop
}
