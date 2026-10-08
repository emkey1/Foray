import AppKit
import RFFileSystem
import RFModel

/// The small cloud on items whose contents are only in the cloud (not downloaded).
final class CloudBadgeView: NSImageView {
    static let size: CGFloat = 13

    override init(frame: NSRect) {
        super.init(frame: frame)
        image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "In the cloud")
        contentTintColor = .secondaryLabelColor
        imageScaling = .scaleProportionallyUpOrDown
        isHidden = true
        toolTip = "Not downloaded: opening it downloads it"
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(for item: FileItem) { isHidden = !item.flags.contains(.dataless) }
}

extension BrowserViewController {
    var selectedCloudItems: [FileItem] { state.selectedItems.filter { CloudLocations.isCloudItem($0.url) || $0.flags.contains(.dataless) } }

    /// Download Now: files (and everything in folders) that are only in the cloud.
    @objc func downloadNow(_ sender: Any?) {
        let urls = selectedCloudItems.map(\.url)
        guard !urls.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            for url in urls { await CloudLocations.download(url) }
        }
    }

    /// Remove Download: keeps the items in the cloud, frees the space here.
    @objc func removeDownload(_ sender: Any?) {
        let urls = selectedCloudItems.filter { !$0.flags.contains(.dataless) }.map(\.url)
        guard !urls.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            var failures: [String] = []
            for url in urls {
                do { try CloudLocations.removeDownload(url) } catch { failures.append(url.lastPathComponent) }
            }
            guard !failures.isEmpty else { return }
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Some downloads couldn't be removed."
                alert.informativeText = "\(ListFormatter.localizedString(byJoining: failures)) may have changes that haven't been uploaded yet, or may be open in an app."
                alert.runModal()
            }
        }
    }
}
