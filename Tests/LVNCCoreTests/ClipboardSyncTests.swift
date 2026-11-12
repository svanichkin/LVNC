import AppKit
@testable import LVNCCore
import XCTest

/// Uses private named pasteboards, never the user's clipboard.
final class ClipboardSyncTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("lvnc-test-\(UUID().uuidString)"))
    }

    private func drainMain(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The sender closes its descriptors after `send` returns, like after a socket send;
    /// the kernel would have given the receiver its own copies. Simulate that with dup().
    private func received(_ m: ClipboardMsg) -> ClipboardMsg {
        var copy = m
        copy.fds = m.fds.map { dup($0) }
        return copy
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func png() -> Data {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
    }

    func testCopiedImageFileArrivesAsFileAndImage() throws {
        let pbA = pasteboard(), pbB = pasteboard()
        var sent: [ClipboardMsg] = []
        let a = ClipboardSync(tag: "A", pasteboard: pbA) { sent.append(self.received($0)) }
        let b = ClipboardSync(tag: "B", pasteboard: pbB) { _ in }

        let dir = try tempDir()
        let image = png()
        let file = dir.appendingPathComponent("картинка.png")
        try image.write(to: file)
        pbA.clearContents()
        pbA.writeObjects([file as NSURL])
        pbA.setString("картинка.png", forType: .string)

        a.poll()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].files.map(\.path), ["картинка.png"])
        XCTAssertEqual(sent[0].fds.count, 1)
        XCTAssertTrue(sent[0].items.allSatisfy { $0.data.count < 100 }, "file contents must not travel in-band")

        b.apply(sent[0])
        drainMain()

        let urls = pbB.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        let got = try XCTUnwrap(urls?.first)
        XCTAssertEqual(got.lastPathComponent, "картинка.png")
        XCTAssertNotEqual(got.deletingLastPathComponent(), dir)
        XCTAssertEqual(try Data(contentsOf: got), image)
        XCTAssertEqual(pbB.data(forType: .png), image)
        XCTAssertNotNil(pbB.data(forType: .tiff))
    }

    func testCopiedFolderArrivesWithContents() throws {
        let pbA = pasteboard(), pbB = pasteboard()
        var sent: [ClipboardMsg] = []
        let a = ClipboardSync(tag: "A", pasteboard: pbA) { sent.append(self.received($0)) }
        let b = ClipboardSync(tag: "B", pasteboard: pbB) { _ in }

        let root = try tempDir().appendingPathComponent("Проект")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("readme.txt"))
        try Data(repeating: 7, count: 300_000).write(to: root.appendingPathComponent("src/deep/blob.bin"))
        let single = root.deletingLastPathComponent().appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: single)

        pbA.clearContents()
        pbA.writeObjects([root as NSURL, single as NSURL])
        a.poll()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].fds.count, 3)

        b.apply(sent[0])
        drainMain()

        let urls = try XCTUnwrap(pbB.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Проект", "note.txt"])
        let folder = urls[0]
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("readme.txt")), Data("a".utf8))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("src/deep/blob.bin")).count, 300_000)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("empty").path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(try Data(contentsOf: urls[1]), Data("note".utf8))
    }

    func testTextIsNotSentTwiceOrEchoed() {
        let pbA = pasteboard(), pbB = pasteboard()
        var fromA: [ClipboardMsg] = [], fromB: [ClipboardMsg] = []
        let a = ClipboardSync(tag: "A", pasteboard: pbA) { fromA.append($0) }
        let b = ClipboardSync(tag: "B", pasteboard: pbB) { fromB.append($0) }

        pbA.clearContents(); pbA.setString("hello", forType: .string)
        a.poll()
        pbA.clearContents(); pbA.setString("hello", forType: .string) // same content rewritten
        a.poll()
        XCTAssertEqual(fromA.count, 1)

        b.apply(fromA[0])
        drainMain()
        XCTAssertEqual(pbB.string(forType: .string), "hello")
        b.poll() // must not send it back
        XCTAssertTrue(fromB.isEmpty)
    }

    func testConcealedContentStaysLocal() {
        let pb = pasteboard()
        var sent: [ClipboardMsg] = []
        let a = ClipboardSync(tag: "A", pasteboard: pb) { sent.append($0) }
        let item = NSPasteboardItem()
        item.setString("secret", forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.clearContents(); pb.writeObjects([item])
        a.poll()
        XCTAssertTrue(sent.isEmpty)
    }
}
