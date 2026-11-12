import CoreVideo
@testable import LVNCCore
import XCTest

final class GPUTileDifferTests: XCTestCase {
    private let w = 300, h = 200, tile = 64 // partial tiles on the right and bottom edge

    private func makeBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                    kCVPixelBufferMetalCompatibilityKey as String: true]
        XCTAssertEqual(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb), kCVReturnSuccess)
        return try XCTUnwrap(pb)
    }

    private func write(_ pb: CVPixelBuffer, _ pixels: [UInt32]) {
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
        pixels.withUnsafeBytes { src in
            for y in 0 ..< h { memcpy(base + y * stride, src.baseAddress! + y * w * 4, w * 4) }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
    }

    func testFindsExactlyTheChangedTiles() throws {
        guard let gpu = GPUTileDiffer(width: w, height: h, tile: tile) else { throw XCTSkip("no Metal device") }
        let tilesX = (w + tile - 1) / tile, tilesY = (h + tile - 1) / tile
        var pixels = (0 ..< w * h).map { _ in UInt32.random(in: 0 ... .max) | 0xFF00_0000 }
        let buffers = try (0 ..< 3).map { _ in try makeBuffer() } // capture rotates buffers too

        write(buffers[0], pixels)
        XCTAssertEqual(gpu.changedTiles(buffers[0])?.count, tilesX * tilesY, "first frame: everything")

        for step in 1 ..< 60 {
            var expected = Set<Int>()
            for _ in 0 ..< Int.random(in: 0 ... 5) {
                // One pixel per chosen tile, anywhere in it, including the partial edge tiles.
                let x = Int.random(in: 0 ..< w), y = Int.random(in: 0 ..< h)
                pixels[y * w + x] ^= 0x0000_0001 // smallest possible change
                expected.insert((y / tile) * tilesX + x / tile)
            }
            if step == 7 { pixels[(h - 1) * w + (w - 1)] ^= 0x10; expected.insert(tilesX * tilesY - 1) } // last pixel
            let pb = buffers[step % 3]
            write(pb, pixels)
            let got = try XCTUnwrap(gpu.changedTiles(pb))
            XCTAssertEqual(Set(got), expected, "step \(step)")
        }
    }

    func testInvalidateReportsEverything() throws {
        guard let gpu = GPUTileDiffer(width: w, height: h, tile: tile) else { throw XCTSkip("no Metal device") }
        let pb = try makeBuffer()
        write(pb, Array(repeating: 0xFF00_0000, count: w * h))
        _ = gpu.changedTiles(pb)
        XCTAssertEqual(gpu.changedTiles(pb), [], "same frame again: nothing")
        gpu.invalidate()
        XCTAssertEqual(gpu.changedTiles(pb)?.count, 4 * 5)
    }

    func testRejectsWrongSize() throws {
        guard let gpu = GPUTileDiffer(width: w + 1, height: h, tile: tile) else { throw XCTSkip("no Metal device") }
        XCTAssertNil(gpu.changedTiles(try makeBuffer()))
    }

    func testCopiesChangedTilesIntoSharedMemory() throws {
        let stride = w * 4, offset = 16384 // like a frame buffer after the header page
        let region = try SharedRegion.create(size: offset + (stride * h + 16383) / 16384 * 16384)
        guard let gpu = GPUTileDiffer(width: w, height: h, tile: tile, region: region) else { throw XCTSkip("no Metal device") }
        let tilesX = (w + tile - 1) / tile
        var pixels = (0 ..< w * h).map { _ in UInt32.random(in: 0 ... .max) | 0xFF00_0000 }
        let buffers = try (0 ..< 3).map { _ in try makeBuffer() }
        let out = (region.base + offset).bindMemory(to: UInt32.self, capacity: w * h)

        for step in 0 ..< 30 {
            if step > 0 {
                for _ in 0 ..< Int.random(in: 1 ... 8) {
                    let x = Int.random(in: 0 ..< w), y = Int.random(in: 0 ..< h)
                    pixels[y * w + x] = UInt32.random(in: 0 ... .max) | 0xFF00_0000
                }
            }
            let pb = buffers[step % 3]
            write(pb, pixels)
            let tiles = try XCTUnwrap(gpu.changedTiles(pb))
            let rects = tiles.map { t -> Rect in
                let x = (t % tilesX) * tile, y = (t / tilesX) * tile
                return Rect(x: x, y: y, w: min(tile, w - x), h: min(tile, h - y))
            }
            XCTAssertTrue(gpu.copyOut(rects, offset: offset, stride: stride))
            for r in rects {
                for y in Int(r.y) ..< Int(r.y + r.h) { for x in Int(r.x) ..< Int(r.x + r.w) where out[y * w + x] != pixels[y * w + x] {
                    return XCTFail("step \(step): pixel (\(x),\(y)) not copied")
                } }
            }
        }
        // Every pixel was in some changed tile on the first frame and kept up to date since.
        for i in 0 ..< w * h where out[i] != pixels[i] { return XCTFail("pixel \(i) stale") }
    }
}
