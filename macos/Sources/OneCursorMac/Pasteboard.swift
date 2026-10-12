import AppKit
import OneCursorCore

/// Watches the general pasteboard for changes made by the user and applies
/// clipboard contents received from other screens.
public final class PasteboardWatcher {
    public var onChange: ((ClipboardContent) -> Void)?
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    public init() {}

    public func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func current() -> ClipboardContent {
        let pb = NSPasteboard.general
        return ClipboardContent(text: pb.string(forType: .string), html: pb.string(forType: .html))
    }

    /// Puts remote clipboard contents on the pasteboard without reporting it back as a local change.
    public func set(_ content: ClipboardContent) {
        guard content.text != nil || content.html != nil else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let text = content.text { pb.setString(text, forType: .string) }
        if let html = content.html { pb.setString(html, forType: .html) }
        lastChangeCount = pb.changeCount
    }

    private func poll() {
        let count = NSPasteboard.general.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        let content = current()
        if !content.isEmpty { onChange?(content) }
    }
}
