import AppKit

/// Yellow/black diagonal stripes, like a road barrier: marks the window as the *remote* screen.
final class HazardStripeView: NSView {
    static let yellow = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)
    static let black = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)

    /// Band thickness grows with the strip's width: a 7 pt strip gets 7 pt bands, the wide
    /// full-screen strips get proportionally bolder ones. Yellow and black are equal.
    private var band: CGFloat { max(7, (bounds.width * 0.75).rounded()) }
    private var period: CGFloat { band * 2 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Never stretch the drawn stripes while the window is resized: keep them pinned to
        // the top and redraw for every new size.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true } // stripes continue seamlessly from the top when resizing

    override func draw(_ dirtyRect: NSRect) {
        Self.black.setFill()
        bounds.fill()

        let w = bounds.width
        let path = NSBezierPath()
        var y = -w
        while y < bounds.height + w {
            // A 45° band from the left edge at y down to the right edge.
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: 0, y: y + band))
            path.line(to: NSPoint(x: w, y: y + band + w))
            path.line(to: NSPoint(x: w, y: y + w))
            path.close()
            y += period
        }
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        Self.yellow.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Window content: hazard stripes on the left and right, the remote screen between them.
final class HazardFrameView: NSView {
    static let stripeWidth: CGFloat = 7

    let remote: NSView
    private let left = HazardStripeView()
    private let right = HazardStripeView()

    init(remote: NSView) {
        self.remote = remote
        super.init(frame: .zero)
        addSubview(left)
        addSubview(remote)
        addSubview(right)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Width / height of the remote screen.
    var contentAspect: CGFloat = 0 { didSet { needsLayout = true } }

    /// In full screen the window has the display's proportions (minus the camera housing),
    /// not the remote screen's: the remote screen is fitted and the stripes fill whatever
    /// is left on the sides instead of black bars.
    var fillsSides = false { didSet { needsLayout = true } }

    override func layout() {
        super.layout()
        let h = bounds.height
        var side = Self.stripeWidth
        if fillsSides, contentAspect > 0 {
            let width = min(bounds.width, (h * contentAspect).rounded())
            side = ((bounds.width - width) / 2).rounded(.down)
        }
        let showStripes = side >= 1
        left.isHidden = !showStripes
        right.isHidden = !showStripes
        guard showStripes else {
            remote.frame = bounds
            return
        }
        left.frame = NSRect(x: 0, y: 0, width: side, height: h)
        right.frame = NSRect(x: bounds.width - side, y: 0, width: side, height: h)
        remote.frame = NSRect(x: side, y: 0, width: max(0, bounds.width - 2 * side), height: h)
    }
}
