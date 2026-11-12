import AppKit
import LVNCCore

let usage = """
usage: lvnc-viewer [<user> | --socket <path>]

Shows and controls the session of <user>, whose lvnc-agent listens on
\(lvncRunDir)/<user>.sock. Without arguments, connects to the running agent
of another user (asks if there are several).

While the window is focused, all keys (including ⌘-combinations) go to the remote
session. Close the window to quit.
"""

let myUser = String(cString: getpwuid(getuid()).pointee.pw_name)

/// Agent sockets created by other users. Not probed by connecting: a connection would
/// take over the agent from a viewer that is already attached.
func discoverAgents() -> [(user: String, path: String)] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: lvncRunDir)) ?? []
    return names.sorted().compactMap { name in
        guard name.hasSuffix(".sock") else { return nil }
        let path = "\(lvncRunDir)/\(name)"
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid != getuid() else { return nil }
        return (String(name.dropLast(5)), path)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let requestedPath: String?
    private var socketPath: String?
    private var client: ViewerClient?
    private var window: NSWindow?
    private var view: RemoteView?
    private var keyMonitor: Any?
    private var quitting = false

    init(socketPath: String?) {
        requestedPath = socketPath
    }

    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
        watchForUpdates()

        guard let path = requestedPath ?? chooseAgent() else {
            NSApp.terminate(nil)
            return
        }
        socketPath = path
        connect()
    }

    /// When the app bundle is replaced (scripts/install.sh), start the new build and quit.
    private func watchForUpdates() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app", let exe = Bundle.main.executablePath else { return }
        func identity() -> String? {
            guard let a = try? FileManager.default.attributesOfItem(atPath: exe) else { return nil }
            return "\(a[.systemFileNumber] ?? 0)-\(a[.modificationDate] ?? 0)"
        }
        let original = identity()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let now = identity(), now != original else { return }
            self?.updateTimer?.invalidate()
            lvncLog("viewer", "app updated, relaunching")
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = Array(CommandLine.arguments.dropFirst())
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
                DispatchQueue.main.async {
                    if let error { lvncLog("viewer", "relaunch failed: \(error)"); return }
                    self?.quitting = true
                    if NSApp.modalWindow != nil { NSApp.abortModal() }
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps firing while an alert is up
        updateTimer = timer
    }

    // MARK: connection

    private func chooseAgent() -> String? {
        let agents = discoverAgents()
        if agents.count == 1 { return agents[0].path }

        let alert = NSAlert()
        if agents.isEmpty {
            alert.messageText = "Агент LVNC не найден"
            alert.informativeText = "Ни один пользователь не запустил lvnc-agent (ищу сокеты в \(lvncRunDir))."
            alert.addButton(withTitle: "Повторить")
            alert.addButton(withTitle: "Выйти")
            return alert.runModal() == .alertFirstButtonReturn ? chooseAgent() : nil
        }
        alert.messageText = "К чьему экрану подключиться?"
        for agent in agents.prefix(3) { alert.addButton(withTitle: agent.user) }
        alert.addButton(withTitle: "Отмена")
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return index < min(agents.count, 3) ? agents[index].path : nil
    }

    private func connect() {
        do {
            try tryConnect()
        } catch WireError.versionMismatch(let v) {
            lvncLog("viewer", "agent protocol \(v), waiting for it to update")
            reconnectQuietly(reason: "\(WireError.versionMismatch(agent: v))")
        } catch {
            lvncLog("viewer", "\(error)")
            failed("Не удалось подключиться", "\(error)")
        }
    }

    private func tryConnect() throws {
        guard let path = socketPath else { return }
        let client = try ViewerClient(socketPath: path)
        lvncLog("viewer", "connected to \(client.hello.userName): \(client.layout.width)x\(client.layout.height)")
        attach(client)
    }

    private var reconnectTimer: Timer?

    /// The agent restarts itself on updates: retry quietly for a while before bothering the user.
    private func reconnectQuietly(reason: String) {
        let deadline = Date().addingTimeInterval(20)
        if let name = client?.hello.userName { window?.title = "LVNC — \(name) (переподключение…)" }
        reconnectTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, !self.quitting else { timer.invalidate(); return }
            do {
                try self.tryConnect()
                timer.invalidate()
            } catch {
                if Date() > deadline {
                    timer.invalidate()
                    lvncLog("viewer", "reconnect gave up: \(error)")
                    self.failed("Соединение закрыто", "\(reason)\n\n\(error)")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reconnectTimer = timer
    }

    private func attach(_ client: ViewerClient) {
        self.client = client
        if let view {
            view.client = client
        } else {
            createWindow(for: client)
        }
        window?.title = "LVNC — \(client.hello.userName)"
        window?.invalidateCursorRects(for: view!)
        frameView?.contentAspect = CGFloat(client.layout.width) / CGFloat(max(1, client.layout.height))

        client.onUpdate = { [weak self] image in self?.view?.show(image) }
        client.onCursor = { [weak self] shape in self?.view?.setRemoteCursor(shape) }
        client.onClose = { [weak self] reason in
            lvncLog("viewer", "closed: \(reason)")
            guard let self, !self.quitting else { return }
            self.reconnectQuietly(reason: reason)
        }
        client.start()
        lastActivity = nil
        updateActivity()
        lastInputSource = nil
        syncInputSource()
        lastDisplayRate = nil
        syncDisplayRate()
    }

    // MARK: display refresh rate (the agent captures no faster)

    private var lastDisplayRate: Int?
    private var screenObserver: Any?

    private func syncDisplayRate() {
        if screenObserver == nil, let window {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
            ) { [weak self] _ in self?.syncDisplayRate() }
        }
        guard let client, let screen = window?.screen ?? NSScreen.main else { return }
        let rate = screen.maximumFramesPerSecond
        guard rate > 0, rate != lastDisplayRate else { return }
        lastDisplayRate = rate
        lvncLog("viewer", "display: \(rate) Hz")
        client.send(.displayRate(UInt32(rate)))
    }

    // MARK: keyboard layout (follow ours on the other side)

    private var lastInputSource: String?
    private var inputSourceObserver: Any?

    /// Karabiner, ⌃Space etc. switch the source here without a key event reaching the
    /// remote side, so mirror the selection instead.
    private func syncInputSource() {
        if inputSourceObserver == nil {
            inputSourceObserver = DistributedNotificationCenter.default().addObserver(
                forName: InputSources.changedNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.syncInputSource() }
        }
        guard let id = InputSources.currentID(), id != lastInputSource, let client else { return }
        lastInputSource = id
        lvncLog("viewer", "input source: \(id)")
        client.send(.inputSource(id))
    }

    // MARK: activity (how much the agent should capture)

    private var lastActivity: ViewerActivity?

    private func currentActivity() -> ViewerActivity {
        guard let window, !NSApp.isHidden, !window.isMiniaturized, window.occlusionState.contains(.visible) else {
            return .hidden
        }
        return NSApp.isActive && window.isKeyWindow ? .active : .background
    }

    @objc private func updateActivity() {
        let activity = currentActivity()
        guard activity != lastActivity, let client else { return }
        lastActivity = activity
        lvncLog("viewer", "activity: \(activity)")
        client.send(.activity(activity))
    }

    private func observeActivity() {
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
            NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ]
        for name in names {
            nc.addObserver(self, selector: #selector(updateActivity), name: name, object: nil)
        }
    }

    /// Offer to reconnect (the agent restarts itself after updates).
    private func failed(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Переподключиться")
        alert.addButton(withTitle: "Выйти")
        if alert.runModal() == .alertFirstButtonReturn {
            connect()
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: window

    private func createWindow(for client: ViewerClient) {
        let view = RemoteView(client: client)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: initialContentSize(client.layout)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = HazardFrameView(remote: view)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.setFrameAutosaveName("LVNCViewer")
        if !window.setFrameUsingName("LVNCViewer") { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.view = view
        self.window = window
        observeActivity()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.isKeyWindow else { return event }
            self.view?.handleKey(event)
            return nil
        }
    }

    /// 1:1 pixels on this screen, shrunk to fit if needed.
    private func initialContentSize(_ layout: FrameLayout) -> NSSize {
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        var size = NSSize(width: CGFloat(layout.width) / scale, height: CGFloat(layout.height) / scale)
        if let visible = screen?.visibleFrame {
            let fit = min(1, visible.width * 0.95 / size.width, (visible.height - 40) * 0.95 / size.height)
            size = NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        }
        return NSSize(width: size.width + 2 * HazardFrameView.stripeWidth, height: size.height)
    }

    /// Keep the remote screen's proportions while resizing, stripes excluded.
    /// Set from the start of entering full screen until it has been left: the system sizes
    /// the window then (to the screen, no title bar) and must not be second-guessed.
    private var fullScreen = false

    private var frameView: HazardFrameView? { window?.contentView as? HazardFrameView }

    func windowWillEnterFullScreen(_ notification: Notification) {
        fullScreen = true
        frameView?.fillsSides = true
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        frameView?.fillsSides = false
    }

    func windowDidExitFullScreen(_ notification: Notification) { fullScreen = false }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullScreen = false
        frameView?.fillsSides = false
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !fullScreen, !sender.styleMask.contains(.fullScreen) else { return frameSize }
        guard let client, client.layout.height > 0 else { return frameSize }
        let aspect = CGFloat(client.layout.width) / CGFloat(client.layout.height)
        let stripes = 2 * HazardFrameView.stripeWidth
        var content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        content.height = ((content.width - stripes) / aspect).rounded()
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "LVNC \(lvncVersion)", action: nil, keyEquivalent: ""))
        appMenu.addItem(.separator())
        // No ⌘Q shortcut on purpose: keys go to the remote session.
        appMenu.addItem(NSMenuItem(title: "Выйти из LVNC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    func windowDidResignKey(_ notification: Notification) {
        view?.releaseKeys()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        view?.releaseKeys()
        client?.disconnect()
    }
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN)

let args = Array(CommandLine.arguments.dropFirst())
var socketPath: String?
if args.first == "--socket", args.count == 2 {
    socketPath = args[1]
} else if args.count == 1, !args[0].hasPrefix("-") {
    socketPath = lvncSocketPath(forUser: args[0])
} else if !args.isEmpty {
    print(usage)
    exit(args.contains("-h") || args.contains("--help") ? 0 : 2)
}

// Started from the Dock/Finder: stderr goes nowhere, keep a log instead.
if isatty(STDERR_FILENO) == 0 {
    let path = "/Users/Shared/lvnc/logs/viewer-\(myUser).log"
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path), (attrs[.size] as? Int ?? 0) > 5 << 20 {
        try? FileManager.default.removeItem(atPath: path)
    }
    freopen(path, "a", stderr)
    setvbuf(stderr, nil, _IOLBF, 0)
}
lvncLog("viewer", "lvnc-viewer \(lvncVersion) (built \(lvncBuildStamp)), pid \(getpid())")

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(socketPath: socketPath)
app.delegate = delegate
app.run()
