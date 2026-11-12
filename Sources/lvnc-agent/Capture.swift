import CoreMedia
import CoreVideo
import Foundation
import LVNCCore
import ScreenCaptureKit

/// Called synchronously with a BGRA frame; the pointer is only valid during the call.
/// `changed`: areas that may differ from the previous frame, in frame pixels; nil = unknown
/// (compare everything).
/// `pixelBuffer`: the frame itself when it is a capture buffer (lets the GPU compare it).
typealias FrameSink = (_ base: UnsafeRawPointer, _ stride: Int, _ width: Int, _ height: Int,
                       _ changed: [CGRect]?, _ pixelBuffer: CVPixelBuffer?) -> Void

protocol FrameSource: AnyObject {
    func start()
    func stop()
    /// Change capture rates; a running source restarts with them.
    func setRates(stream: Int, snapshot: Int)
}

/// ScreenCaptureKit capture of one display.
///
/// Starts with an SCStream. When the stream fails (typically: the session was switched
/// to the background by Fast User Switching) it falls back to polling SCScreenshotManager,
/// which keeps working for a background session.
final class ScreenSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    private let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private var streamFPS: Int    // only changed on `queue`
    private var snapshotFPS: Int  // only changed on `queue`
    private let snapshotOnly: Bool
    private let showsCursor: Bool
    private let sink: FrameSink
    private let onFatal: (Error) -> Void

    private let queue = DispatchQueue(label: "lvnc.capture")
    private let sampleQueue = DispatchQueue(label: "lvnc.capture.samples")

    // All state below is only touched on `queue`.
    private var running = false
    private var generation = 0
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private var timer: DispatchSourceTimer?
    private var busy = false
    private var contentStale = false
    private var errorCount = 0
    private var snapshotFrames = 0

    init(displayID: CGDirectDisplayID, width: Int, height: Int, streamFPS: Int, snapshotFPS: Int,
         snapshotOnly: Bool, showsCursor: Bool, sink: @escaping FrameSink, onFatal: @escaping (Error) -> Void) {
        self.showsCursor = showsCursor
        self.displayID = displayID
        self.width = width
        self.height = height
        self.streamFPS = streamFPS
        self.snapshotFPS = snapshotFPS
        self.snapshotOnly = snapshotOnly
        self.sink = sink
        self.onFatal = onFatal
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.begin()
        }
    }

    func stop() {
        queue.async {
            guard self.running else { return }
            self.teardown()
            lvncLog("capture", "stopped")
        }
    }

    func setRates(stream: Int, snapshot: Int) {
        queue.async {
            guard stream != self.streamFPS || snapshot != self.snapshotFPS else { return }
            self.streamFPS = stream
            self.snapshotFPS = snapshot
            lvncLog("capture", "rate: stream \(stream) fps, snapshots \(snapshot) fps")
            if self.running {
                self.teardown()
                self.begin()
            }
        }
    }

    private func begin() {
        running = true
        generation += 1
        if snapshotOnly {
            lvncLog("capture", "snapshot mode forced, \(snapshotFPS) fps")
            startSnapshots()
            return
        }
        let gen = generation
        refreshContent { ok in
            guard gen == self.generation else { return }
            if ok { self.startStream() } else { self.startSnapshots() }
        }
    }

    private func teardown() {
        running = false
        generation += 1
        timer?.cancel()
        timer = nil
        stream?.stopCapture { _ in }
        stream = nil
        busy = false
    }

    // MARK: content

    /// Look up the display and build filter + config. Output size is pinned to the size
    /// the agent started with, so the framebuffer layout never changes. Calls back on `queue`.
    private func refreshContent(_ done: @escaping (Bool) -> Void) {
        SCShareableContent.getWithCompletionHandler { content, error in
            self.queue.async {
                if let error {
                    if Self.isPermissionError(error) { self.onFatal(error); return }
                    self.logError("shareable content", error)
                    done(false)
                    return
                }
                let displays = content?.displays ?? []
                guard let display = displays.first(where: { $0.displayID == self.displayID }) ?? displays.first else {
                    self.logError("shareable content", WireError.protocolError("no displays visible to ScreenCaptureKit"))
                    done(false)
                    return
                }
                if display.displayID != self.displayID {
                    lvncLog("capture", "display \(self.displayID) not listed, using \(display.displayID)")
                }

                let config = SCStreamConfiguration()
                config.width = self.width
                config.height = self.height
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, self.streamFPS)))
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.showsCursor = self.showsCursor
                config.queueDepth = 4

                self.config = config
                self.filter = SCContentFilter(display: display, excludingWindows: [])
                self.contentStale = false
                done(true)
            }
        }
    }

    // MARK: stream

    private func startStream() {
        guard running, let filter, let config else { return }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            streamFailed(error)
            return
        }
        self.stream = stream
        stream.startCapture { error in
            self.queue.async {
                if let error {
                    if stream === self.stream { self.streamFailed(error) }
                } else {
                    lvncLog("capture", "stream started \(self.width)x\(self.height) @\(self.streamFPS) fps")
                }
            }
        }
    }

    private func streamFailed(_ error: Error) {
        if Self.isPermissionError(error) { onFatal(error); return }
        let e = error as NSError
        lvncLog("capture", "stream stopped: \(e.localizedDescription) (\(e.domain) \(e.code)) -> snapshots at \(snapshotFPS) fps")
        stream = nil
        contentStale = true
        startSnapshots()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            if stream === self.stream { self.streamFailed(error) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        deliver(sampleBuffer, fromStream: true)
    }

    // MARK: snapshots

    private func startSnapshots() {
        guard running, timer == nil else { return }
        let fps = max(1, snapshotFPS)
        let interval = DispatchTimeInterval.nanoseconds(1_000_000_000 / fps)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.snapshotTick() }
        t.resume()
        timer = t
    }

    /// Skips a tick if the previous one has not completed.
    private func snapshotTick() {
        guard running, !busy else { return }
        busy = true
        let gen = generation

        guard let filter, let config, !contentStale else {
            refreshContent { _ in
                if gen == self.generation { self.busy = false }
            }
            return
        }

        SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config) { sampleBuffer, error in
            if let sampleBuffer, gen == self.generation {
                self.deliver(sampleBuffer)
            }
            self.queue.async {
                guard gen == self.generation else { return }
                if let error {
                    if Self.isPermissionError(error) { self.onFatal(error); return }
                    self.logError("snapshot", error)
                    self.contentStale = true
                } else if sampleBuffer != nil {
                    if self.snapshotFrames == 0 { lvncLog("capture", "first snapshot frame") }
                    self.snapshotFrames += 1
                    self.errorCount = 0
                }
                self.busy = false
            }
        }
    }

    // MARK: helpers

    /// `fromStream`: stream frames carry ScreenCaptureKit's own change info; snapshots do not.
    private func deliver(_ sampleBuffer: CMSampleBuffer, fromStream: Bool = false) {
        var changed: [CGRect]?
        if fromStream {
            guard let info = Self.frameInfo(sampleBuffer) else { return }
            if let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .idle { return } // nothing changed
            changed = Self.changedRects(info)
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)

        // Dirty rects may be in points or pixels; scale by frame width over content width.
        // Over-covering only costs a little comparing, so take the larger interpretation.
        if var rects = changed, let info = Self.frameInfo(sampleBuffer) {
            let content = (info[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
            let scale = max(1, CGFloat(width) / max(1, content?.width ?? CGFloat(width)))
            rects = rects.map { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale) }
            if !loggedDirtyRects, rects.isEmpty == false, let first = rects.first {
                loggedDirtyRects = true
                lvncLog("capture", "using ScreenCaptureKit dirty rects (scale \(scale), first \(first.integral))")
            }
            changed = rects
        }
        sink(UnsafeRawPointer(base), CVPixelBufferGetBytesPerRow(pb), width, height, changed, pb)
    }

    private var loggedDirtyRects = false

    private static func frameInfo(_ sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
    }

    private static var loggedDirtyFormat = false

    /// The rects arrive as an array of CGRect dictionaries or NSValues depending on the
    /// system; anything else means "unknown" (compare everything) and is logged once.
    private static func changedRects(_ info: [SCStreamFrameInfo: Any]) -> [CGRect]? {
        guard let value = info[.dirtyRects] else {
            if !loggedDirtyFormat {
                loggedDirtyFormat = true
                lvncLog("capture", "no dirty rects in frame info (keys: \(info.keys.map(\.rawValue).sorted()))")
            }
            return nil
        }
        if let list = value as? [NSDictionary] {
            return list.compactMap { CGRect(dictionaryRepresentation: $0) }
        }
        if let list = value as? [NSValue] {
            return list.map(\.rectValue)
        }
        if !loggedDirtyFormat {
            loggedDirtyFormat = true
            lvncLog("capture", "unknown dirty rects format: \(type(of: value)) \(String(describing: value).prefix(200))")
        }
        return nil
    }

    /// First error of a streak, then every 100th, so polling does not flood the log.
    private func logError(_ what: String, _ error: Error) {
        if errorCount % 100 == 0 {
            let e = error as NSError
            lvncLog("capture", "\(what) failed (#\(errorCount + 1)): \(e.localizedDescription) (\(e.domain) \(e.code))")
        }
        errorCount += 1
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == SCStreamErrorDomain && e.code == SCStreamError.Code.userDeclined.rawValue
    }
}

/// Synthetic frames (gradient + moving square) for testing the pipeline without
/// screen recording permission.
final class TestPatternSource: FrameSource {
    private let width: Int
    private let height: Int
    private var fps: Int
    private let sink: FrameSink
    private let queue = DispatchQueue(label: "lvnc.testpattern")
    private var timer: DispatchSourceTimer?
    private var background: [UInt8]
    private var frame: [UInt8]
    private var tick = 0

    init(width: Int, height: Int, fps: Int, sink: @escaping FrameSink) {
        self.width = width
        self.height = height
        self.fps = fps
        self.sink = sink
        background = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = (y * width + x) * 4
                background[i] = UInt8(x * 255 / max(1, width - 1))      // B
                background[i + 1] = UInt8(y * 255 / max(1, height - 1)) // G
                background[i + 2] = 64                                  // R
                background[i + 3] = 255                                 // A
            }
        }
        frame = background
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / max(1, self.fps)))
            t.setEventHandler { self.render() }
            t.resume()
            self.timer = t
            lvncLog("capture", "test pattern \(self.width)x\(self.height) @\(self.fps) fps")
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    func setRates(stream: Int, snapshot: Int) {
        queue.async {
            guard stream != self.fps else { return }
            self.fps = stream
            lvncLog("capture", "test pattern rate \(stream) fps")
            self.timer?.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / max(1, stream)))
        }
    }

    private func render() {
        frame = background
        let size = min(120, width / 4, height / 4)
        let span = max(1, width - size)
        let x0 = (tick * 8) % span
        let y0 = (height - size) / 2
        for y in y0 ..< y0 + size {
            for x in x0 ..< x0 + size {
                let i = (y * width + x) * 4
                frame[i] = 255; frame[i + 1] = 255; frame[i + 2] = 255
            }
        }
        tick += 1
        frame.withUnsafeBytes { sink($0.baseAddress!, width * 4, width, height, nil, nil) }
    }
}
