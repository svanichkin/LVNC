import CoreGraphics
import Foundation
import LVNCCore

/// Posts mouse and keyboard events into the session the agent runs in.
final class InputInjector {
    private let bounds: CGRect // captured display, in global points
    private let enabled: Bool
    private let source = CGEventSource(stateID: .privateState)
    private let queue = DispatchQueue(label: "lvnc.input")

    // Only touched on `queue`.
    private var flags = CGEventFlags()
    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<UInt8>()
    private var lastPoint = CGPoint.zero
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var dragOrigin: CGPoint?  // a drag of the viewer's files is in progress
    private var dragFailed = false    // it did not start: ignore the viewer's drag events until it lets go
    private let drags = DragSource()

    /// Virtual key codes of modifier keys; they are posted as flagsChanged events.
    private static let modifierKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    init(bounds: CGRect, enabled: Bool) {
        self.bounds = bounds
        self.enabled = enabled
    }

    func handle(_ message: Message) {
        queue.async {
            switch message {
            case .mouse(let m): self.mouse(m)
            case .scroll(let s): self.scroll(s)
            case .key(let k): self.key(k)
            case .dragBegin(let d): self.beginDrag(d)
            case .dragCancel: self.cancelDrag()
            default: break
            }
        }
    }

    /// Release everything the viewer left pressed (it disconnected or lost focus).
    func releaseAll() {
        queue.async {
            self.cancelDrag() // a mouse-up elsewhere would drop the files there
            for code in self.heldKeys {
                self.key(KeyMsg(keyCode: code, down: false, isRepeat: false, flags: 0))
            }
            for button in self.heldButtons {
                self.postMouse(action: .up, button: button, clickCount: 1, at: self.lastPoint)
            }
            self.heldKeys.removeAll()
            self.heldButtons.removeAll()
            self.flags = []
        }
    }

    private func point(_ m: MouseMsg) -> CGPoint {
        let x = min(max(m.x, 0), 1), y = min(max(m.y, 0), 1)
        return CGPoint(x: bounds.minX + x * (bounds.width - 1), y: bounds.minY + y * (bounds.height - 1))
    }

    private func mouse(_ m: MouseMsg) {
        if dragFailed, m.button == 0, m.action == .drag || m.action == .up {
            if m.action == .up { dragFailed = false }
            return
        }
        dragFailed = false
        let p = point(m)
        lastPoint = p
        switch m.action {
        case .down: heldButtons.insert(m.button)
        case .up:
            heldButtons.remove(m.button)
            if m.button == 0, dragOrigin != nil {
                dragOrigin = nil
                lvncLog("agent", "drag: dropping")
            }
        default: break
        }
        postMouse(action: m.action, button: m.button, clickCount: m.clickCount, at: p)
    }

    /// Files dragged into the viewer: start a drag with them here (see `DragSource`).
    /// The following `.mouse(.drag)` messages move it, `.mouse(.up)` drops it.
    private func beginDrag(_ d: DragMsg) {
        cancelDrag()
        guard enabled else { d.files.closeFDs(); return }
        let p = point(MouseMsg(action: .down, button: 0, clickCount: 1, x: d.x, y: d.y))
        guard drags.prepare(d.files, at: p) else { return }
        dragOrigin = p
        lastPoint = p
        heldButtons.insert(0)
        postMouse(action: .move, button: 0, clickCount: 0, at: p)
        postMouse(action: .down, button: 0, clickCount: 1, at: p)
        guard drags.waitForStart() else {
            // The mouse-down went to whatever is under the panel: finish that click right
            // there, so the viewer's drag does not drag things around in that app.
            postMouse(action: .up, button: 0, clickCount: 1, at: p)
            heldButtons.remove(0)
            dragOrigin = nil
            dragFailed = true
            lvncLog("agent", "drag: the mouse-down did not reach the drag panel, drag not started")
            return
        }
    }

    /// Release the drag over its own panel, which accepts nothing.
    private func cancelDrag() {
        dragFailed = false
        guard let origin = dragOrigin else { return }
        dragOrigin = nil
        heldButtons.remove(0)
        lastPoint = origin
        postMouse(action: .drag, button: 0, clickCount: 0, at: origin)
        postMouse(action: .up, button: 0, clickCount: 1, at: origin)
        lvncLog("agent", "drag: cancelling")
    }

    private func postMouse(action: MouseAction, button: UInt8, clickCount: UInt8, at p: CGPoint) {
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case 0:
            cgButton = .left
            type = [.move: .mouseMoved, .down: .leftMouseDown, .up: .leftMouseUp, .drag: .leftMouseDragged][action]!
        case 1:
            cgButton = .right
            type = [.move: .mouseMoved, .down: .rightMouseDown, .up: .rightMouseUp, .drag: .rightMouseDragged][action]!
        default:
            cgButton = .center
            type = [.move: .mouseMoved, .down: .otherMouseDown, .up: .otherMouseUp, .drag: .otherMouseDragged][action]!
        }
        guard enabled, let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton) else { return }
        if action == .down || action == .up {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        }
        if button >= 2 {
            e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        }
        e.flags = flags
        e.post(tap: .cgSessionEventTap)
    }

    private func scroll(_ s: ScrollMsg) {
        let dx = s.dx + scrollRemainder.x, dy = s.dy + scrollRemainder.y
        let ix = Int32(dx.rounded(.towardZero)), iy = Int32(dy.rounded(.towardZero))
        scrollRemainder = (dx - Double(ix), dy - Double(iy))
        guard enabled, ix != 0 || iy != 0,
              let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0)
        else { return }
        e.flags = flags
        e.post(tap: .cgSessionEventTap)
    }

    private func key(_ k: KeyMsg) {
        flags = CGEventFlags(rawValue: k.flags)
        if k.down { heldKeys.insert(k.keyCode) } else { heldKeys.remove(k.keyCode) }
        guard enabled, let e = CGEvent(keyboardEventSource: source, virtualKey: k.keyCode, keyDown: k.down) else { return }
        if Self.modifierKeys.contains(k.keyCode) {
            e.type = .flagsChanged
        }
        if k.isRepeat {
            e.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        e.flags = flags
        e.post(tap: .cgSessionEventTap)
    }
}
