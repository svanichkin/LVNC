import CLVNC
import Foundation

/// Framed messages over a connected Unix stream socket: [u32 kind][u32 length][payload].
/// File descriptors a message carries (clipboard files) ride along via SCM_RIGHTS.
/// send() is thread-safe; receive() is meant for a single reader thread.
public final class Connection {
    public let fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false
    /// Descriptors received but not yet handed out with a message (reader thread only).
    private var pendingFDs: [Int32] = []

    /// Large enough for clipboard images (see ClipboardSync.maxBytes).
    private static let maxPayload = 80 << 20

    public init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close()
        for fd in pendingFDs { Darwin.close(fd) }
    }

    /// Sends the message; its attached descriptors stay owned by the caller.
    public func send(_ message: Message) throws {
        let payload = message.payload()
        var w = WireWriter()
        w.u32(message.kind.rawValue)
        w.u32(UInt32(payload.count))
        w.bytes(payload)

        let fds = message.attachedFDs
        guard fds.count <= Int(LVNC_MAX_FDS) else { throw WireError.protocolError("too many descriptors (\(fds.count))") }

        writeLock.lock()
        defer { writeLock.unlock() }
        let rc = w.bytes.withUnsafeBytes { buf in
            fds.withUnsafeBufferPointer { lvnc_send_with_fds(fd, buf.baseAddress, buf.count, $0.baseAddress, Int32(fds.count)) }
        }
        if rc != 0 { throw WireError.io(errno) }
    }

    /// Next known message. A clipboard message comes with its descriptors (caller owns them).
    public func receive() throws -> Message {
        while true {
            var r = WireReader(try readExactly(8))
            let kind = try r.u32()
            let length = Int(try r.u32())
            guard length <= Self.maxPayload else { throw WireError.protocolError("payload of \(length) bytes") }
            let payload = length > 0 ? try readExactly(length) : []
            guard let message = try Message.decode(kind: kind, payload: payload) else { continue }

            if case .clipboard(var c) = message {
                let need = c.fileFDCount
                guard pendingFDs.count >= need else {
                    throw WireError.protocolError("clipboard lists \(need) files but \(pendingFDs.count) descriptors arrived")
                }
                c.fds = Array(pendingFDs.prefix(need))
                pendingFDs.removeFirst(need)
                return .clipboard(c)
            }
            return message
        }
    }

    /// Unblocks a pending receive() on another thread, then releases the fd.
    public func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private func readExactly(_ count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var received = [Int32](repeating: -1, count: Int(LVNC_MAX_FDS))
        try out.withUnsafeMutableBytes { buf in
            var off = 0
            while off < count {
                var nfds: Int32 = 0
                let n = received.withUnsafeMutableBufferPointer {
                    lvnc_recv_with_fds(fd, buf.baseAddress! + off, count - off, $0.baseAddress, &nfds)
                }
                if nfds > 0 { pendingFDs.append(contentsOf: received.prefix(Int(nfds))) }
                if n == 0 { throw WireError.closed }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw WireError.io(errno)
                }
                off += n
            }
        }
        return out
    }
}
