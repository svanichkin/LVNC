import AppKit
import LVNCCore

/// Watches the session's cursor shape and reports changes, so the viewer can show its own
/// cursor (no latency) with the remote shape instead of a cursor baked into the frames.
final class CursorWatcher {
    private let send: (CursorMsg) -> Void
    private var timer: DispatchSourceTimer?
    private var lastFingerprint: Int?

    /// `send` is called on the main queue.
    init(send: @escaping (CursorMsg) -> Void) {
        self.send = send
    }

    func start() {
        DispatchQueue.main.async {
            guard self.timer == nil else { return }
            self.lastFingerprint = nil // always report the current shape to a new viewer
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: .milliseconds(66), leeway: .milliseconds(10))
            t.setEventHandler { self.poll() } // cycle broken by stop()
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func poll() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard image.size.width > 0, let png = Self.png(image) else { return }

        var h = Hasher()
        h.combine(cursor.hotSpot.x); h.combine(cursor.hotSpot.y)
        png.withUnsafeBytes { h.combine(bytes: $0) }
        let fingerprint = h.finalize()
        guard fingerprint != lastFingerprint else { return }
        if lastFingerprint == nil {
            lvncLog("cursor", "shape \(Int(image.size.width))x\(Int(image.size.height)) pt, hot spot \(cursor.hotSpot), \(png.count) bytes")
        }
        lastFingerprint = fingerprint

        send(CursorMsg(png: [UInt8](png), width: image.size.width, height: image.size.height,
                       hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y))
    }

    /// The sharpest representation (Retina) as PNG.
    private static func png(_ image: NSImage) -> Data? {
        let best = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max { $0.pixelsWide < $1.pixelsWide }
        if let best { return best.representation(using: .png, properties: [:]) }

        // Not a bitmap (e.g. PDF): render at 2x.
        let w = Int(image.size.width * 2), h = Int(image.size.height * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
