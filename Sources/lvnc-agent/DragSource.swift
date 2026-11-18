import AppKit
import LVNCCore

/// Starts a real drag and drop in this session with files the viewer dragged in, so they
/// land wherever they are dropped (a Finder folder, a chat, a mail).
///
/// Only an app can start a drag, from a mouse-down in one of its windows. So a tiny, almost
/// transparent panel is put under the point where the files entered, `InputInjector` posts a
/// mouse-down onto it and the panel's view begins the dragging session. The viewer's
/// drag updates then arrive as ordinary mouse drags and the mouse-up drops. To cancel, the
/// pointer goes back to the panel (it accepts nothing) and is released there.
final class DragSource: NSObject, NSDraggingSource {
    /// Where received files are kept (each user's own temporary folder).
    private static let dropRoot = FileManager.default.temporaryDirectory.appendingPathComponent("LVNC-drop", isDirectory: true)
    private static let panelSize: CGFloat = 8

    // Main thread only.
    private var panel: NSPanel?
    private var pending: [URL] = []      // files for the next mouse-down on the panel
    private var dropFolder: URL?         // of the drag being prepared or in progress
    /// Signalled when the posted mouse-down has started the dragging session.
    private let sessionBegan = DispatchSemaphore(value: 0)

    /// Any thread except main (blocks on it). Clones the files and puts the panel under `point`
    /// (global display coordinates, origin top-left). Closes the message's descriptors.
    /// false if the files could not be received; then no mouse-down must be posted.
    func prepare(_ message: ClipboardMsg, at point: CGPoint) -> Bool {
        defer { message.closeFDs() }
        let started = Date()
        let tops: [URL]
        do {
            tops = try FileTransfer.materialize(message, under: Self.dropRoot, keep: 10)
        } catch {
            lvncLog("agent", "drag: cannot receive files: \(error)")
            return false
        }
        guard !tops.isEmpty else { return false }
        lvncLog("agent", "drag in: \(FileTransfer.describe(message.files)), saved in \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        while sessionBegan.wait(timeout: .now()) == .success {} // stale signal of an earlier drag
        let window = DispatchQueue.main.sync { () -> CGWindowID in
            self.pending = tops
            self.dropFolder = tops[0].deletingLastPathComponent()
            return self.showPanel(at: point)
        }
        // The mouse-down only hits the panel once the window server shows it there.
        let deadline = Date().addingTimeInterval(0.5)
        while !Self.isOnScreen(window, at: point), Date() < deadline { usleep(5_000) }
        if Date() >= deadline { lvncLog("agent", "drag: panel not on screen after 500 ms, trying anyway") }
        return true
    }

    /// After posting the mouse-down: whether it reached the panel and the drag began.
    /// If not, the panel is hidden and the files are dropped.
    func waitForStart() -> Bool {
        if sessionBegan.wait(timeout: .now() + 0.5) == .success { return true }
        DispatchQueue.main.sync {
            self.pending = []
            self.panel?.orderOut(nil)
            if let dropFolder = self.dropFolder { try? FileManager.default.removeItem(at: dropFolder) }
            self.dropFolder = nil
        }
        return false
    }

    private static func isOnScreen(_ window: CGWindowID, at point: CGPoint) -> Bool {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return false }
        return bounds.insetBy(dx: -1, dy: -1).contains(point)
    }

    private func showPanel(at point: CGPoint) -> CGWindowID {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Cocoa screen coordinates have their origin at the bottom-left of the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let s = Self.panelSize
        panel.setFrame(NSRect(x: point.x - s / 2, y: primaryHeight - point.y - s / 2, width: s, height: s), display: false)
        panel.orderFrontRegardless()
        return CGWindowID(panel.windowNumber)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelSize, height: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Fully transparent pixels let clicks through; this is invisible but still hit.
        panel.backgroundColor = NSColor(white: 1, alpha: 0.02)
        panel.contentView = OriginView(owner: self)
        return panel
    }

    fileprivate func begin(from view: NSView, with event: NSEvent) {
        guard !pending.isEmpty else {
            lvncLog("agent", "drag: mouse-down on the panel, but no files are waiting")
            return
        }
        let items = pending.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            // The viewer already shows the drag image on its side; a second one would lag behind.
            item.setDraggingFrame(NSRect(x: 0, y: 0, width: 1, height: 1), contents: Self.blank)
            return item
        }
        pending = []
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
        lvncLog("agent", "drag: started with \(items.count) items")
        sessionBegan.signal()
    }

    private static let blank = NSImage(size: NSSize(width: 1, height: 1))

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        panel?.orderOut(nil)
        if operation.isEmpty {
            lvncLog("agent", "drag: cancelled or nothing accepted the files")
            if let dropFolder { try? FileManager.default.removeItem(at: dropFolder) }
        } else {
            lvncLog("agent", "drag: dropped")
        }
        dropFolder = nil
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

/// The panel's content: starts the drag on the posted mouse-down.
private final class OriginView: NSView {
    private weak var owner: DragSource?

    init(owner: DragSource) {
        self.owner = owner
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.begin(from: self, with: event) }
}
