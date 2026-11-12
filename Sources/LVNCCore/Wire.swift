import Foundation

public let lvncVersion = "0.7.1"
public let lvncProtocolVersion: UInt32 = 2

/// First bytes on a fresh connection, sent by the agent together with the shared memory fd.
public let lvncMagic: [UInt8] = Array("LVNC".utf8)

public let lvncRunDir = "/Users/Shared/lvnc/run"
public func lvncSocketPath(forUser user: String) -> String { "\(lvncRunDir)/\(user).sock" }

// MARK: - Logging

public func lvncLog(_ tag: String, _ message: String) {
    var tv = timeval()
    gettimeofday(&tv, nil)
    var t = tv.tv_sec
    var parts = tm()
    localtime_r(&t, &parts)
    let stamp = String(format: "%02d:%02d:%02d.%03d", parts.tm_hour, parts.tm_min, parts.tm_sec, Int(tv.tv_usec / 1000))
    fputs("\(stamp) [\(tag)] \(message)\n", stderr)
}

// MARK: - Little-endian encoding

public enum WireError: Error, CustomStringConvertible {
    case truncated
    case closed
    case io(Int32)
    case protocolError(String)
    case versionMismatch(agent: UInt32)

    public var description: String {
        switch self {
        case .truncated: return "truncated message"
        case .closed: return "connection closed"
        case .io(let e): return String(cString: strerror(e))
        case .protocolError(let s): return "protocol error: \(s)"
        case .versionMismatch(let v): return "agent speaks protocol \(v), viewer \(lvncProtocolVersion) (one side is not updated yet)"
        }
    }
}

public struct WireWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }
    public mutating func bytes(_ b: [UInt8]) { bytes.append(contentsOf: b) }
}

public struct WireReader {
    private let bytes: [UInt8]
    private var pos = 0
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    private mutating func take<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let n = MemoryLayout<T>.size
        guard pos + n <= bytes.count else { throw WireError.truncated }
        var v: T = 0
        withUnsafeMutableBytes(of: &v) { dst in
            bytes.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[pos ..< pos + n]))
            }
        }
        pos += n
        return T(littleEndian: v)
    }

    public mutating func u8() throws -> UInt8 { try take(UInt8.self) }
    public mutating func u16() throws -> UInt16 { try take(UInt16.self) }
    public mutating func u32() throws -> UInt32 { try take(UInt32.self) }
    public mutating func u64() throws -> UInt64 { try take(UInt64.self) }
    public mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    public mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, pos + count <= bytes.count else { throw WireError.truncated }
        defer { pos += count }
        return Array(bytes[pos ..< pos + count])
    }
}

/// Build time of the binary, so a stale copy is easy to spot in the log.
public let lvncBuildStamp: String = {
    guard let exe = Bundle.main.executablePath,
          let date = (try? FileManager.default.attributesOfItem(atPath: exe))?[.modificationDate] as? Date
    else { return "?" }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}()
