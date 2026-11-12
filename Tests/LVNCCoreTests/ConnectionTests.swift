import Foundation
@testable import LVNCCore
import XCTest

final class ConnectionTests: XCTestCase {
    private func pair() -> (Connection, Connection) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (Connection(fd: fds[0]), Connection(fd: fds[1]))
    }

    func testClipboardRoundTrip() throws {
        let (a, b) = pair()
        let image = [UInt8]((0 ..< 3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sent = ClipboardMsg(items: [
            .init(type: "public.utf8-plain-text", data: Array("привет, LVNC".utf8)),
            .init(type: "public.png", data: image),
        ])
        // Large payloads would fill the socket buffer: send from another thread.
        Thread { try? a.send(.clipboard(sent)) }.start()

        guard case .clipboard(let got) = try b.receive() else { return XCTFail("wrong message") }
        XCTAssertEqual(got.items.map(\.type), sent.items.map(\.type))
        XCTAssertEqual(got.items.map(\.data), sent.items.map(\.data))
    }

    func testInputAndFrameRoundTrip() throws {
        let (a, b) = pair()
        try a.send(.key(KeyMsg(keyCode: 12, down: true, isRepeat: false, flags: 1 << 20)))
        try a.send(.mouse(MouseMsg(action: .drag, button: 1, clickCount: 0, x: 0.25, y: 0.75)))
        try a.send(.frame(FrameMsg(buffer: 2, seq: 7, rects: [Rect(x: 64, y: 128, w: 32, h: 16)])))

        guard case .key(let k) = try b.receive() else { return XCTFail() }
        XCTAssertEqual(k.keyCode, 12); XCTAssertTrue(k.down); XCTAssertEqual(k.flags, 1 << 20)
        guard case .mouse(let m) = try b.receive() else { return XCTFail() }
        XCTAssertEqual(m.action, .drag); XCTAssertEqual(m.button, 1); XCTAssertEqual(m.x, 0.25); XCTAssertEqual(m.y, 0.75)
        guard case .frame(let f) = try b.receive() else { return XCTFail() }
        XCTAssertEqual(f.buffer, 2); XCTAssertEqual(f.seq, 7); XCTAssertEqual(f.rects.first?.w, 32)
    }

    func testClipboardDescriptorsTravelWithTheMessage() throws {
        let (a, b) = pair()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("через дескриптор".utf8).write(to: file)
        let fd = open(file.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)

        // Frames around it must not disturb the descriptor bookkeeping.
        try a.send(.release(1))
        try a.send(.clipboard(ClipboardMsg(items: [], files: [.init(path: "f.txt", isDirectory: false, size: 31)], fds: [fd])))
        close(fd) // the receiver has its own copy now
        try a.send(.release(2))

        guard case .release(1) = try b.receive() else { return XCTFail() }
        guard case .clipboard(let c) = try b.receive() else { return XCTFail() }
        XCTAssertEqual(c.fds.count, 1)
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(c.fds[0], &buf, buf.count)
        XCTAssertEqual(String(decoding: buf.prefix(max(0, n)), as: UTF8.self), "через дескриптор")
        c.closeFDs()
        guard case .release(2) = try b.receive() else { return XCTFail() }
    }

    func testCursorRoundTrip() throws {
        let (a, b) = pair()
        try a.send(.cursor(CursorMsg(png: [1, 2, 3], width: 23, height: 22, hotX: 11.5, hotY: 11)))
        guard case .cursor(let c) = try b.receive() else { return XCTFail() }
        XCTAssertEqual(c.png, [1, 2, 3]); XCTAssertEqual(c.width, 23); XCTAssertEqual(c.hotX, 11.5)
    }

    func testDisplayRateRoundTrip() throws {
        let (a, b) = pair()
        try a.send(.displayRate(120))
        guard case .displayRate(let fps) = try b.receive() else { return XCTFail() }
        XCTAssertEqual(fps, 120)
    }

    func testClosedPeer() {
        let (a, b) = pair()
        a.close()
        XCTAssertThrowsError(try b.receive())
    }
}
