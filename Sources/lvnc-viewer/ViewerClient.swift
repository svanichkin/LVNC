import CLVNC
import CoreGraphics
import Foundation
import IOSurface
import LVNCCore

/// Connection to an agent: receives the shared memory, keeps a local copy of the
/// remote screen up to date, sends input.
final class ViewerClient {
    let hello: Hello
    let layout: FrameLayout
    private let conn: Connection
    private let region: SharedRegion

    /// The remote screen, updated rect by rect on the reader thread.
    private let surfaces: SurfaceChain

    private let displayLock = NSLock()  // guards the two below
    private var displayScheduled = false
    private var latest: IOSurface?
    private var stats = ViewerStats() // guarded by displayLock

    /// Called on the main thread with the surface to show.
    var onUpdate: ((IOSurface) -> Void)?
    /// Called on the main thread when the remote cursor changes shape.
    var onCursor: ((CursorMsg) -> Void)?
    /// Called on the main thread when the agent goes away.
    var onClose: ((String) -> Void)?

    init(socketPath: String) throws {
        let fd = lvnc_unix_connect(socketPath)
        guard fd >= 0 else {
            throw WireError.protocolError("cannot connect to \(socketPath): \(String(cString: strerror(errno)))")
        }

        var magic = [UInt8](repeating: 0, count: lvncMagic.count)
        var shmFD: Int32 = -1
        let n = magic.withUnsafeMutableBytes { lvnc_recv_fd(fd, $0.baseAddress, $0.count, &shmFD) }
        guard n == lvncMagic.count, magic == lvncMagic, shmFD >= 0 else {
            close(fd)
            if shmFD >= 0 { close(shmFD) }
            throw WireError.protocolError(n == 0 ? "agent closed the connection (is this user in --allow?)" : "bad handshake")
        }
        conn = Connection(fd: fd)

        guard case .hello(let hello) = try conn.receive() else {
            throw WireError.protocolError("expected hello")
        }
        guard hello.version == lvncProtocolVersion else {
            throw WireError.versionMismatch(agent: hello.version)
        }
        self.hello = hello
        layout = FrameLayout(hello: hello)
        guard layout.totalSize <= Int(hello.shmSize) else { throw WireError.protocolError("inconsistent layout") }
        region = try SharedRegion.map(fd: shmFD, size: Int(hello.shmSize), writable: false)

        surfaces = try SurfaceChain(width: layout.width, height: layout.height, region: region)
        lvncLog("viewer", "drawing with \(surfaces.usesGPU ? "the GPU" : "the CPU")")
    }

    private lazy var clipboard = ClipboardSync(tag: "viewer") { [weak self] message in
        self?.send(.clipboard(message))
    }

    func start() {
        clipboard.start()
        Thread { self.readLoop() }.start()
    }

    func send(_ message: Message) {
        try? conn.send(message)
    }

    func disconnect() {
        clipboard.stop()
        conn.close()
    }

    private func readLoop() {
        var reason = "агент отключился"
        do {
            while true {
                switch try conn.receive() {
                case .frame(let frame):
                    let started = DispatchTime.now()
                    apply(frame)
                    try conn.send(.release(frame.buffer))
                    let nanos = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
                    displayLock.lock(); stats.applied(nanos: nanos); displayLock.unlock()
                    scheduleDisplay()
                case .clipboard(let c):
                    clipboard.apply(c)
                case .cursor(let shape):
                    DispatchQueue.main.async { self.onCursor?(shape) }
                default:
                    break
                }
            }
        } catch WireError.closed {
            // keep the default reason
        } catch {
            reason = "\(error)"
        }
        clipboard.stop()
        DispatchQueue.main.async { self.onClose?(reason) }
    }

    /// Copy the frame's dirty rects from shared memory into the next surface.
    private func apply(_ frame: FrameMsg) {
        let index = Int(frame.buffer)
        guard index < layout.bufferCount else { return }
        let src = UnsafeRawPointer(region.base) + layout.offset(ofBuffer: index)
        let surface = surfaces.apply(frame.rects, from: src, sourceStride: layout.stride)
        displayLock.lock()
        latest = surface
        displayLock.unlock()
    }

    /// Coalesce: at most one pending main-thread update, always showing the newest surface.
    private func scheduleDisplay() {
        displayLock.lock()
        let already = displayScheduled
        displayScheduled = true
        displayLock.unlock()
        guard !already else { return }

        DispatchQueue.main.async {
            self.displayLock.lock()
            self.displayScheduled = false
            let surface = self.latest
            self.displayLock.unlock()
            guard let surface else { return }
            self.onUpdate?(surface)
            self.surfaces.didShow(surface)
            self.displayLock.lock()
            self.stats.shown += 1
            let line = self.stats.report()
            self.displayLock.unlock()
            if let line { lvncLog("viewer", line) }
        }
    }
}

/// Every 10 s while frames flow: received, apply cost, shown.
private struct ViewerStats {
    private var since = DispatchTime.now()
    private var received = 0, applyNanos: UInt64 = 0, maxApplyNanos: UInt64 = 0
    var shown = 0

    mutating func applied(nanos: UInt64) {
        received += 1
        applyNanos += nanos
        maxApplyNanos = max(maxApplyNanos, nanos)
    }

    mutating func report() -> String? {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1e9
        guard elapsed >= 10 else { return nil }
        defer { self = ViewerStats() }
        return String(format: "received %.1f/s (apply avg %.1f ms, max %.1f) -> shown %.1f/s",
                      Double(received) / elapsed, Double(applyNanos) / Double(max(1, received)) / 1e6,
                      Double(maxApplyNanos) / 1e6, Double(shown) / elapsed)
    }
}
