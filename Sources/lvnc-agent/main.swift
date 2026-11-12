import ApplicationServices
import CLVNC
import CoreGraphics
import Foundation
import LVNCCore

// MARK: - Options

struct Options {
    var allowUsers: [String] = []
    var socketPath: String?
    var fps: Int? // nil: follow the viewer's display refresh rate
    var snapshotFPS = 15
    var snapshotOnly = false
    var scale: Double? // capture scale over display points; default: native pixels
    var testPattern = false
    var viewOnly = false
    var noClipboard = false
    var drawCursor = false

    static let usage = """
    usage: lvnc-agent --allow <user>[,<user>...] [options]

    Runs in the session to be controlled. Shares its screen and accepts input over a
    Unix socket; only the listed users may connect (checked by peer uid).

      --allow <users>     comma-separated user names allowed to connect (required)
      --socket <path>     socket path (default \(lvncRunDir)/<this user>.sock)
      --fps <n>           cap the frame rate (default: the viewer's display refresh rate)
      --snapshot          poll snapshots instead of streaming
      --snapshot-fps <n>  snapshot rate when polling (default 15)
      --scale <x>         capture scale relative to display points, e.g. 1 (default: native)
      --view-only         do not inject input
      --no-clipboard      do not share the clipboard
      --draw-cursor       draw the cursor into frames instead of sending its shape
      --test-pattern      synthetic frames, no screen capture, no input (for testing)
    """

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var it = args.dropFirst().makeIterator()
        func value(_ flag: String) -> String {
            guard let v = it.next() else { fail("\(flag) needs a value") }
            return v
        }
        while let a = it.next() {
            switch a {
            case "--allow": o.allowUsers += value(a).split(separator: ",").map(String.init)
            case "--socket": o.socketPath = value(a)
            case "--fps": o.fps = Int(value(a))
            case "--snapshot": o.snapshotOnly = true
            case "--snapshot-fps": o.snapshotFPS = Int(value(a)) ?? o.snapshotFPS
            case "--scale": o.scale = Double(value(a))
            case "--view-only": o.viewOnly = true
            case "--no-clipboard": o.noClipboard = true
            case "--draw-cursor": o.drawCursor = true
            case "--test-pattern": o.testPattern = true
            case "-h", "--help": print(usage); exit(0)
            default: fail("unknown option \(a)")
            }
        }
        if o.allowUsers.isEmpty { fail("--allow is required") }
        return o
    }
}

func fail(_ message: String) -> Never {
    fputs("lvnc-agent: \(message)\n\n\(Options.usage)\n", stderr)
    exit(2)
}

func uid(of user: String) -> uid_t? {
    guard let pw = getpwnam(user) else { return nil }
    return pw.pointee.pw_uid
}

let currentUser = String(cString: getpwuid(getuid()).pointee.pw_name)

// MARK: - Agent

final class Agent {
    private let options: Options
    private let allowed: [uid_t: String]
    private let layout: FrameLayout
    private let region: SharedRegion
    private let publisher: FramePublisher
    private let injector: InputInjector
    private var source: FrameSource!
    private let socketPath: String

    private let lock = NSLock()
    private var current: Connection?
    private var cursorWatcher: CursorWatcher? // of the current session; guarded by `lock`
    private var updateTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []

    init(options: Options) throws {
        self.options = options

        var allowed: [uid_t: String] = [:]
        for user in options.allowUsers {
            guard let id = uid(of: user) else { fail("no such user: \(user)") }
            allowed[id] = user
        }
        self.allowed = allowed
        socketPath = options.socketPath ?? lvncSocketPath(forUser: currentUser)

        let display = CGMainDisplayID()
        let bounds = CGDisplayBounds(display)
        let width: Int, height: Int
        if options.testPattern {
            (width, height) = (1280, 800)
        } else {
            let scale = options.scale ?? Self.nativeScale(display)
            width = Int((bounds.width * scale).rounded())
            height = Int((bounds.height * scale).rounded())
            lvncLog("agent", "display \(display): \(Int(bounds.width))x\(Int(bounds.height)) pt, capturing \(width)x\(height) px")
        }

        layout = FrameLayout(width: width, height: height)
        region = try SharedRegion.create(size: layout.totalSize)
        publisher = FramePublisher(layout: layout, region: region)
        injector = InputInjector(bounds: bounds, enabled: !(options.viewOnly || options.testPattern))

        let publisher = self.publisher
        let sink: FrameSink = { base, stride, w, h, changed, pixelBuffer in
            publisher.submit(base: base, stride: stride, width: w, height: h, changed: changed, pixelBuffer: pixelBuffer)
        }
        if options.testPattern {
            source = TestPatternSource(width: width, height: height, fps: options.fps ?? 30, sink: sink)
        } else {
            source = ScreenSource(displayID: display, width: width, height: height,
                                  streamFPS: options.fps ?? 60, snapshotFPS: options.snapshotFPS,
                                  snapshotOnly: options.snapshotOnly, showsCursor: options.drawCursor,
                                  sink: sink) { error in
                lvncLog("agent", "screen recording permission denied: \(error.localizedDescription)")
                lvncLog("agent", "grant it in System Settings > Privacy & Security > Screen Recording, then restart")
                exit(1)
            }
        }
    }

    static func nativeScale(_ display: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    func run() throws {
        try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let listenFD = lvnc_unix_listen(socketPath, 4)
        guard listenFD >= 0 else { throw WireError.io(errno) }
        let who = allowed.sorted { $0.key < $1.key }.map { "\($0.value)(\($0.key))" }.joined(separator: ", ")
        lvncLog("agent", "ready on \(socketPath), allowed: \(who)")

        Thread { self.acceptLoop(listenFD) }.start()
        watchForUpdates()

        // Remove the socket on a normal stop, so viewers don't find a dead agent.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [socketPath] in
                lvncLog("agent", "signal \(sig), exiting")
                unlink(socketPath)
                exit(0)
            }
            s.resume()
            signalSources.append(s)
        }
    }

    /// Under launchd (KeepAlive) exit when the binary is replaced, so the new build takes over.
    private func watchForUpdates() {
        guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]?.hasPrefix("local.lvnc.agent") == true,
              let exe = Bundle.main.executablePath else { return }
        func identity() -> String? {
            guard let a = try? FileManager.default.attributesOfItem(atPath: exe) else { return nil }
            return "\(a[.systemFileNumber] ?? 0)-\(a[.modificationDate] ?? 0)"
        }
        let original = identity()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler {
            let now = identity()
            if now != nil, now != original {
                lvncLog("agent", "binary updated, exiting so launchd starts the new one")
                exit(0)
            }
        }
        t.resume()
        updateTimer = t
    }

    private func acceptLoop(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno != EINTR { lvncLog("agent", "accept: \(String(cString: strerror(errno)))") }
                continue
            }
            var peer: uid_t = 0
            guard lvnc_peer_uid(fd, &peer) == 0, let name = allowed[peer] else {
                lvncLog("agent", "rejected connection from uid \(peer)")
                close(fd)
                continue
            }
            startSession(fd: fd, user: name)
        }
    }

    private func startSession(fd: Int32, user: String) {
        let conn = Connection(fd: fd)
        let ok = lvncMagic.withUnsafeBytes { lvnc_send_fd(fd, region.fd, $0.baseAddress, $0.count) } == 0
        guard ok else {
            lvncLog("agent", "could not hand over shared memory: \(String(cString: strerror(errno)))")
            conn.close()
            return
        }
        do {
            try conn.send(.hello(Hello(layout: layout, userName: currentUser)))
        } catch {
            lvncLog("agent", "hello failed: \(error)")
            conn.close()
            return
        }

        lock.lock()
        let previous = current
        current = conn
        lock.unlock()
        if let previous {
            lvncLog("agent", "new viewer replaces the previous one")
            previous.close()
        }

        lvncLog("agent", "viewer connected: \(user)")
        publisher.attach(conn)
        viewerRate = nil
        activity = .active
        source.setRates(stream: activeRate, snapshot: options.snapshotFPS)
        source.start()

        let clipboard = ClipboardSync(tag: "agent") { [weak conn] message in
            try? conn?.send(.clipboard(message))
        }
        let cursor = CursorWatcher { [weak conn] shape in try? conn?.send(.cursor(shape)) }
        lock.lock(); cursorWatcher?.stop(); cursorWatcher = options.drawCursor ? nil : cursor; lock.unlock()
        if !options.drawCursor { cursor.start() }
        if !options.noClipboard { clipboard.start() }

        Thread { self.serve(conn, user: user, clipboard: clipboard) }.start()
    }

    /// Capture only as much as the viewer can use.
    private func setActivity(_ activity: ViewerActivity, for conn: Connection) {
        lock.lock()
        let isCurrent = current === conn
        let cursor = cursorWatcher
        lock.unlock()
        guard isCurrent else { return }
        lvncLog("agent", "viewer is \(activity)")
        self.activity = activity
        if activity == .hidden { cursor?.stop() } else { cursor?.start() }
        switch activity {
        case .active:
            source.setRates(stream: activeRate, snapshot: options.snapshotFPS)
            source.start()
        case .background:
            source.setRates(stream: 2, snapshot: 2)
            source.start()
        case .hidden:
            source.stop()
        }
    }

    /// Frame rate while the viewer is focused: --fps if given, else the viewer's display
    /// refresh rate (60 until it tells us).
    private var activeRate: Int { min(options.fps ?? viewerRate ?? 60, viewerRate ?? 240) }
    private var viewerRate: Int?          // serve thread of the current session
    private var activity = ViewerActivity.active

    private func setDisplayRate(_ fps: UInt32, for conn: Connection) {
        lock.lock()
        let isCurrent = current === conn
        lock.unlock()
        guard isCurrent, fps > 0 else { return }
        viewerRate = Int(min(fps, 240))
        lvncLog("agent", "viewer display: \(fps) Hz -> capture up to \(activeRate) fps")
        if activity == .active { source.setRates(stream: activeRate, snapshot: options.snapshotFPS) }
    }

    private func serve(_ conn: Connection, user: String, clipboard: ClipboardSync) {
        do {
            while true {
                let message = try conn.receive()
                switch message {
                case .release(let buffer): publisher.release(buffer)
                case .mouse, .scroll, .key: injector.handle(message)
                case .clipboard(let c): if options.noClipboard { c.closeFDs() } else { clipboard.apply(c) }
                case .activity(let a): setActivity(a, for: conn)
                case .displayRate(let fps): setDisplayRate(fps, for: conn)
                case .inputSource(let id):
                    DispatchQueue.main.async { lvncLog("agent", "input source: \(InputSources.select(id))") }
                default: break
                }
            }
        } catch {
            lvncLog("agent", "viewer \(user) disconnected (\(error))")
        }

        clipboard.stop()
        lock.lock()
        if current === conn { cursorWatcher?.stop(); cursorWatcher = nil }
        lock.unlock()
        publisher.detach(conn)
        injector.releaseAll()
        conn.close()

        lock.lock()
        let wasCurrent = current === conn
        if wasCurrent { current = nil }
        lock.unlock()
        if wasCurrent { source.stop() }
    }
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN)
let options = Options.parse(CommandLine.arguments)
lvncLog("agent", "lvnc-agent \(lvncVersion) (built \(lvncBuildStamp)), pid \(getpid()), user \(currentUser)")

if !options.testPattern {
    if !CGPreflightScreenCaptureAccess() {
        lvncLog("agent", "no screen recording permission yet, requesting it")
        CGRequestScreenCaptureAccess()
    }
    if !options.viewOnly && !AXIsProcessTrusted() {
        lvncLog("agent", "no accessibility permission: input will be ignored until granted (System Settings > Privacy & Security > Accessibility)")
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }
}

do {
    let agent = try Agent(options: options)
    try agent.run()
} catch {
    lvncLog("agent", "fatal: \(error)")
    exit(1)
}
dispatchMain()
