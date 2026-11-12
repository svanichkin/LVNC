import AppKit
import IOSurface
import LVNCCore

/// Shows the remote screen and turns local mouse/keyboard events into messages.
final class RemoteView: NSView {
    /// Replaced on reconnect.
    var client: ViewerClient
    private var trackingArea: NSTrackingArea?
    private var pressedKeys = Set<UInt16>()

    /// Modifier key code -> the flag that tells whether it is down.
    private static let modifierFlag: [UInt16: NSEvent.ModifierFlags] = [
        54: .command, 55: .command,
        56: .shift, 60: .shift,
        58: .option, 61: .option,
        59: .control, 62: .control,
        57: .capsLock,
        63: .function,
    ]

    init(client: ViewerClient) {
        self.client = client
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Our own cursor (no latency) with the remote cursor's shape; frames come without it.
    /// A cursor rect lets AppKit switch it back when the pointer leaves the view.
    private var cursor = NSCursor.arrow

    /// Where the remote screen is drawn: aspect-fit inside the view (letterboxed if the
    /// view's proportions differ, e.g. in full screen).
    var imageRect: NSRect {
        let iw = CGFloat(client.layout.width), ih = CGFloat(client.layout.height)
        guard iw > 0, ih > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / iw, bounds.height / ih)
        let w = iw * scale, h = ih * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    func setRemoteCursor(_ shape: CursorMsg) {
        guard let image = NSImage(data: Data(shape.png)) else { return }
        image.size = NSSize(width: shape.width, height: shape.height)
        cursor = NSCursor(image: image, hotSpot: NSPoint(x: shape.hotX, y: shape.hotY))
        window?.invalidateCursorRects(for: self)
        if let window, window.isKeyWindow,
           imageRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            cursor.set()
        }
    }

    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: cursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    // MARK: mouse

    private func send(_ action: MouseAction, button: Int, _ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let r = imageRect
        guard r.width > 0, r.height > 0 else { return }
        let x = (p.x - r.minX) / r.width
        let y = 1 - (p.y - r.minY) / r.height
        let clicks = action == .move || action == .drag ? 0 : event.clickCount
        client.send(.mouse(MouseMsg(action: action, button: UInt8(clamping: button),
                                    clickCount: UInt8(clamping: clicks), x: x, y: y)))
    }

    override func mouseMoved(with e: NSEvent) { send(.move, button: 0, e) }
    override func mouseDown(with e: NSEvent) { send(.down, button: 0, e) }
    override func mouseUp(with e: NSEvent) { send(.up, button: 0, e) }
    override func mouseDragged(with e: NSEvent) { send(.drag, button: 0, e) }
    override func rightMouseDown(with e: NSEvent) { send(.down, button: 1, e) }
    override func rightMouseUp(with e: NSEvent) { send(.up, button: 1, e) }
    override func rightMouseDragged(with e: NSEvent) { send(.drag, button: 1, e) }
    override func otherMouseDown(with e: NSEvent) { send(.down, button: e.buttonNumber, e) }
    override func otherMouseUp(with e: NSEvent) { send(.up, button: e.buttonNumber, e) }
    override func otherMouseDragged(with e: NSEvent) { send(.drag, button: e.buttonNumber, e) }

    override func scrollWheel(with e: NSEvent) {
        let k = e.hasPreciseScrollingDeltas ? 1.0 : 10.0
        client.send(.scroll(ScrollMsg(dx: e.scrollingDeltaX * k, dy: e.scrollingDeltaY * k)))
    }

    // MARK: keyboard (fed from the app's local event monitor, so ⌘-combinations arrive too)

    func handleKey(_ e: NSEvent) {
        let code = e.keyCode
        let flags = UInt64(e.modifierFlags.rawValue)
        switch e.type {
        case .keyDown:
            pressedKeys.insert(code)
            client.send(.key(KeyMsg(keyCode: code, down: true, isRepeat: e.isARepeat, flags: flags)))
        case .keyUp:
            pressedKeys.remove(code)
            client.send(.key(KeyMsg(keyCode: code, down: false, isRepeat: false, flags: flags)))
        case .flagsChanged:
            guard let mask = Self.modifierFlag[code] else { return }
            let down = e.modifierFlags.contains(mask)
            if down { pressedKeys.insert(code) } else { pressedKeys.remove(code) }
            client.send(.key(KeyMsg(keyCode: code, down: down, isRepeat: false, flags: flags)))
        default:
            break
        }
    }

    /// Focus left the window: let go of everything we hold on the remote side.
    func releaseKeys() {
        for code in pressedKeys {
            client.send(.key(KeyMsg(keyCode: code, down: false, isRepeat: false, flags: 0)))
        }
        pressedKeys.removeAll()
    }
}
