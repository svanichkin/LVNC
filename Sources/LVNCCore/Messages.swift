import Foundation

/// Layout of the shared memory region: a header page, then `bufferCount` BGRA frames.
public struct FrameLayout {
    public let width: Int
    public let height: Int
    public let stride: Int
    public let bufferCount: Int
    public let bufferOffset: Int
    public let bufferSize: Int

    public var totalSize: Int { bufferOffset + bufferCount * bufferSize }
    public func offset(ofBuffer index: Int) -> Int { bufferOffset + index * bufferSize }

    public init(width: Int, height: Int, bufferCount: Int = 3) {
        let page = Int(getpagesize())
        self.width = width
        self.height = height
        self.stride = width * 4
        self.bufferCount = bufferCount
        self.bufferOffset = page
        self.bufferSize = (stride * height + page - 1) / page * page
    }

    public init(hello: Hello) {
        width = Int(hello.width)
        height = Int(hello.height)
        stride = Int(hello.stride)
        bufferCount = Int(hello.bufferCount)
        bufferOffset = Int(hello.bufferOffset)
        bufferSize = Int(hello.bufferSize)
    }
}

/// Agent -> viewer, right after the shared memory fd.
public struct Hello {
    public var version: UInt32
    public var width: UInt32
    public var height: UInt32
    public var stride: UInt32
    public var bufferCount: UInt32
    public var bufferOffset: UInt64
    public var bufferSize: UInt64
    public var shmSize: UInt64
    public var userName: String

    public init(layout: FrameLayout, userName: String) {
        version = lvncProtocolVersion
        width = UInt32(layout.width)
        height = UInt32(layout.height)
        stride = UInt32(layout.stride)
        bufferCount = UInt32(layout.bufferCount)
        bufferOffset = UInt64(layout.bufferOffset)
        bufferSize = UInt64(layout.bufferSize)
        shmSize = UInt64(layout.totalSize)
        self.userName = userName
    }
}

public struct Rect {
    public var x, y, w, h: UInt32
    public init(x: Int, y: Int, w: Int, h: Int) {
        self.x = UInt32(x); self.y = UInt32(y); self.w = UInt32(w); self.h = UInt32(h)
    }
}

/// Agent -> viewer: buffer `buffer` holds new pixels inside `rects` (other pixels in it are stale).
/// The viewer copies them out and answers with `.release(buffer)`.
public struct FrameMsg {
    public var buffer: UInt32
    public var seq: UInt64
    public var rects: [Rect]
    public init(buffer: UInt32, seq: UInt64, rects: [Rect]) {
        self.buffer = buffer; self.seq = seq; self.rects = rects
    }
}

public enum MouseAction: UInt8 {
    case move = 0, down = 1, up = 2, drag = 3
}

/// Viewer -> agent. x, y are normalized to 0...1 over the captured display, origin top-left.
/// button: 0 left, 1 right, 2+ other.
public struct MouseMsg {
    public var action: MouseAction
    public var button: UInt8
    public var clickCount: UInt8
    public var x: Double
    public var y: Double
    public init(action: MouseAction, button: UInt8, clickCount: UInt8, x: Double, y: Double) {
        self.action = action; self.button = button; self.clickCount = clickCount; self.x = x; self.y = y
    }
}

/// Viewer -> agent, deltas in pixels.
public struct ScrollMsg {
    public var dx: Double
    public var dy: Double
    public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }
}

/// Viewer -> agent. keyCode is the macOS virtual key code (physical key);
/// flags are NSEvent/CGEvent modifier flags. Modifier keys are sent with down = pressed.
public struct KeyMsg {
    public var keyCode: UInt16
    public var down: Bool
    public var isRepeat: Bool
    public var flags: UInt64
    public init(keyCode: UInt16, down: Bool, isRepeat: Bool, flags: UInt64) {
        self.keyCode = keyCode; self.down = down; self.isRepeat = isRepeat; self.flags = flags
    }
}

/// Either direction: the sender's pasteboard changed.
///
/// `items`: representations of the first pasteboard item (UTI -> bytes).
/// `files`: copied files and folders, paths relative to the copied selection
/// ("photo.jpg", "Folder", "Folder/a.txt"); parents come before their contents.
/// Regular files carry an open descriptor in `fds` (same order, folders have none),
/// passed with SCM_RIGHTS, so contents never travel through the socket.
public struct ClipboardMsg {
    public struct Item {
        public var type: String
        public var data: [UInt8]
        public init(type: String, data: [UInt8]) { self.type = type; self.data = data }
    }

    public struct FileEntry {
        public var path: String
        public var isDirectory: Bool
        public var size: UInt64
        public init(path: String, isDirectory: Bool, size: UInt64) {
            self.path = path; self.isDirectory = isDirectory; self.size = size
        }
    }

    public var items: [Item]
    public var files: [FileEntry]
    /// One per non-directory entry of `files`. Owned by the message: whoever ends up
    /// with it must call `closeFDs()`.
    public var fds: [Int32]

    public init(items: [Item], files: [FileEntry] = [], fds: [Int32] = []) {
        self.items = items; self.files = files; self.fds = fds
    }

    public var fileFDCount: Int { files.filter { !$0.isDirectory }.count }

    public func closeFDs() {
        for fd in fds { close(fd) }
    }
}

/// Viewer -> agent: how much the viewer needs right now. The agent captures accordingly.
public enum ViewerActivity: UInt8 {
    case active = 0      // window focused: full frame rate
    case background = 1  // visible, focus elsewhere: low frame rate
    case hidden = 2      // not visible (minimized, covered, other Space, app hidden): no capture
}

/// Agent -> viewer: the remote cursor's shape. The viewer shows its own (lag-free)
/// cursor with this image; frames are captured without the cursor.
public struct CursorMsg {
    public var png: [UInt8]
    public var width: Double   // points
    public var height: Double
    public var hotX: Double    // points from the top-left
    public var hotY: Double
    public init(png: [UInt8], width: Double, height: Double, hotX: Double, hotY: Double) {
        self.png = png; self.width = width; self.height = height; self.hotX = hotX; self.hotY = hotY
    }
}

public enum Message {
    case hello(Hello)
    case frame(FrameMsg)
    case release(UInt32)
    case mouse(MouseMsg)
    case scroll(ScrollMsg)
    case key(KeyMsg)
    case clipboard(ClipboardMsg)
    case activity(ViewerActivity)
    /// Viewer -> agent: the viewer's selected keyboard input source (TIS id), so typed key
    /// codes produce the same characters on the other side.
    case inputSource(String)
    case cursor(CursorMsg)
    /// Viewer -> agent: refresh rate of the screen the window is on (frames per second);
    /// the agent captures no faster than that.
    case displayRate(UInt32)

    enum Kind: UInt32 {
        case hello = 1, frame, release, mouse, scroll, key, clipboard, activity, inputSource, cursor, displayRate
    }

    var kind: Kind {
        switch self {
        case .hello: return .hello
        case .frame: return .frame
        case .release: return .release
        case .mouse: return .mouse
        case .scroll: return .scroll
        case .key: return .key
        case .clipboard: return .clipboard
        case .activity: return .activity
        case .inputSource: return .inputSource
        case .cursor: return .cursor
        case .displayRate: return .displayRate
        }
    }

    /// Descriptors to pass along with this message.
    var attachedFDs: [Int32] {
        if case .clipboard(let c) = self { return c.fds }
        return []
    }

    func payload() -> [UInt8] {
        var w = WireWriter()
        switch self {
        case .hello(let h):
            w.u32(h.version); w.u32(h.width); w.u32(h.height); w.u32(h.stride); w.u32(h.bufferCount)
            w.u64(h.bufferOffset); w.u64(h.bufferSize); w.u64(h.shmSize)
            let name = Array(h.userName.utf8.prefix(255))
            w.u8(UInt8(name.count)); w.bytes(name)
        case .frame(let f):
            w.u32(f.buffer); w.u64(f.seq); w.u32(UInt32(f.rects.count))
            for r in f.rects { w.u32(r.x); w.u32(r.y); w.u32(r.w); w.u32(r.h) }
        case .release(let b):
            w.u32(b)
        case .mouse(let m):
            w.u8(m.action.rawValue); w.u8(m.button); w.u8(m.clickCount); w.f64(m.x); w.f64(m.y)
        case .scroll(let s):
            w.f64(s.dx); w.f64(s.dy)
        case .key(let k):
            w.u16(k.keyCode); w.u8(k.down ? 1 : 0); w.u8(k.isRepeat ? 1 : 0); w.u64(k.flags)
        case .clipboard(let c):
            w.u32(UInt32(c.items.count))
            for item in c.items {
                let type = Array(item.type.utf8.prefix(1024))
                w.u16(UInt16(type.count)); w.bytes(type)
                w.u32(UInt32(item.data.count)); w.bytes(item.data)
            }
            w.u32(UInt32(c.files.count))
            for f in c.files {
                let path = Array(f.path.utf8.prefix(4096))
                w.u16(UInt16(path.count)); w.bytes(path)
                w.u8(f.isDirectory ? 1 : 0); w.u64(f.size)
            }
        case .activity(let a):
            w.u8(a.rawValue)
        case .inputSource(let id):
            let bytes = Array(id.utf8.prefix(1024))
            w.u16(UInt16(bytes.count)); w.bytes(bytes)
        case .cursor(let c):
            w.f64(c.width); w.f64(c.height); w.f64(c.hotX); w.f64(c.hotY)
            w.u32(UInt32(c.png.count)); w.bytes(c.png)
        case .displayRate(let fps):
            w.u32(fps)
        }
        return w.bytes
    }

    /// nil for message types this version does not know (they are skipped).
    static func decode(kind rawKind: UInt32, payload: [UInt8]) throws -> Message? {
        guard let kind = Kind(rawValue: rawKind) else { return nil }
        var r = WireReader(payload)
        switch kind {
        case .hello:
            let version = try r.u32(), width = try r.u32(), height = try r.u32(), stride = try r.u32(), count = try r.u32()
            let offset = try r.u64(), size = try r.u64(), shm = try r.u64()
            let nameLen = Int(try r.u8())
            var name: [UInt8] = []
            for _ in 0 ..< nameLen { name.append(try r.u8()) }
            var h = Hello(layout: FrameLayout(width: 1, height: 1), userName: String(decoding: name, as: UTF8.self))
            h.version = version; h.width = width; h.height = height; h.stride = stride; h.bufferCount = count
            h.bufferOffset = offset; h.bufferSize = size; h.shmSize = shm
            return .hello(h)
        case .frame:
            let buffer = try r.u32(), seq = try r.u64(), n = try r.u32()
            guard n <= 100_000 else { throw WireError.protocolError("too many rects") }
            var rects: [Rect] = []
            rects.reserveCapacity(Int(n))
            for _ in 0 ..< n {
                rects.append(Rect(x: Int(try r.u32()), y: Int(try r.u32()), w: Int(try r.u32()), h: Int(try r.u32())))
            }
            return .frame(FrameMsg(buffer: buffer, seq: seq, rects: rects))
        case .release:
            return .release(try r.u32())
        case .mouse:
            let a = try r.u8(), b = try r.u8(), c = try r.u8(), x = try r.f64(), y = try r.f64()
            guard let action = MouseAction(rawValue: a) else { return nil }
            return .mouse(MouseMsg(action: action, button: b, clickCount: c, x: x, y: y))
        case .scroll:
            return .scroll(ScrollMsg(dx: try r.f64(), dy: try r.f64()))
        case .key:
            let code = try r.u16(), down = try r.u8(), rep = try r.u8(), flags = try r.u64()
            return .key(KeyMsg(keyCode: code, down: down != 0, isRepeat: rep != 0, flags: flags))
        case .clipboard:
            let n = try r.u32()
            guard n <= 64 else { throw WireError.protocolError("too many clipboard types") }
            var items: [ClipboardMsg.Item] = []
            for _ in 0 ..< n {
                let type = String(decoding: try r.bytes(Int(try r.u16())), as: UTF8.self)
                let data = try r.bytes(Int(try r.u32()))
                items.append(ClipboardMsg.Item(type: type, data: data))
            }
            let nf = try r.u32()
            guard nf <= 10_000 else { throw WireError.protocolError("too many clipboard files") }
            var files: [ClipboardMsg.FileEntry] = []
            for _ in 0 ..< nf {
                let path = String(decoding: try r.bytes(Int(try r.u16())), as: UTF8.self)
                let isDir = try r.u8() != 0
                files.append(ClipboardMsg.FileEntry(path: path, isDirectory: isDir, size: try r.u64()))
            }
            return .clipboard(ClipboardMsg(items: items, files: files))
        case .activity:
            guard let a = ViewerActivity(rawValue: try r.u8()) else { return nil }
            return .activity(a)
        case .inputSource:
            return .inputSource(String(decoding: try r.bytes(Int(try r.u16())), as: UTF8.self))
        case .cursor:
            let w = try r.f64(), h = try r.f64(), hx = try r.f64(), hy = try r.f64()
            return .cursor(CursorMsg(png: try r.bytes(Int(try r.u32())), width: w, height: h, hotX: hx, hotY: hy))
        case .displayRate:
            return .displayRate(try r.u32())
        }
    }
}
