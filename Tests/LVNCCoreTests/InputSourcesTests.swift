@testable import LVNCCore
import XCTest

/// Read-only: never changes the user's selected input source.
final class InputSourcesTests: XCTestCase {
    func testCurrentSourceIsReadable() throws {
        guard let id = InputSources.currentID() else { throw XCTSkip("no keyboard input source (headless CI)") }
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(InputSources.select(id), "\(id) already selected")
    }

    func testUnknownSourceIsReported() {
        XCTAssertEqual(InputSources.select("org.example.no-such-layout"), "org.example.no-such-layout is not installed here")
    }

    func testInputSourceMessageRoundTrip() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let a = Connection(fd: fds[0]), b = Connection(fd: fds[1])
        try a.send(.inputSource("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"))
        guard case .inputSource(let id) = try b.receive() else { return XCTFail() }
        XCTAssertEqual(id, "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese")
    }
}
