import IOSurface
@testable import LVNCCore
import XCTest

final class SurfaceChainTests: XCTestCase {
    /// Random partial updates, shown in random order: every surface handed out must equal
    /// the reference image, pixel for pixel. CPU path.
    func testEverySurfaceShowsTheCompleteScreenCPU() throws {
        try run(gpu: false)
    }

    /// Same with GPU copies from a read-only mapping of shared memory, as in the viewer.
    func testEverySurfaceShowsTheCompleteScreenGPU() throws {
        try run(gpu: true)
    }

    private func run(gpu: Bool) throws {
        let w = 160, h = 96, stride = w * 4
        // The "agent" writes through one mapping, the chain reads through a read-only one.
        let writer = try SharedRegion.create(size: (stride * h + 16383) / 16384 * 16384)
        let reader = try SharedRegion.map(fd: dup(writer.fd), size: writer.size, writable: false)
        let chain = try SurfaceChain(width: w, height: h, region: gpu ? reader : nil)
        if gpu && !chain.usesGPU { throw XCTSkip("no Metal device") }
        XCTAssertEqual(chain.usesGPU, gpu)

        var reference = [UInt32](repeating: 0xFF1A_1A1A, count: w * h)
        let frame = writer.base.bindMemory(to: UInt32.self, capacity: w * h)
        var rng = SystemRandomNumberGenerator()
        var pendingShow: [IOSurface] = []

        for step in 0 ..< 400 {
            var rects: [Rect] = []
            for _ in 0 ..< Int.random(in: 1 ... (step % 50 == 0 ? 80 : 6), using: &rng) { // sometimes > 64: fully stale
                let x = Int.random(in: 0 ..< w - 1, using: &rng), y = Int.random(in: 0 ..< h - 1, using: &rng)
                let rw = Int.random(in: 1 ... w - x, using: &rng), rh = Int.random(in: 1 ... h - y, using: &rng)
                let color = UInt32.random(in: 0 ... .max, using: &rng) | 0xFF00_0000
                for yy in y ..< y + rh { for xx in x ..< x + rw {
                    reference[yy * w + xx] = color
                    frame[yy * w + xx] = color
                } }
                rects.append(Rect(x: x, y: y, w: rw, h: rh))
            }
            let surface = chain.apply(rects, from: UnsafeRawPointer(reader.base), sourceStride: stride)
            assertEqual(surface, reference, w: w, h: h, step: step)

            // The main thread shows surfaces late and sometimes skips some.
            pendingShow.append(surface)
            if Bool.random(using: &rng) {
                chain.didShow(pendingShow.last!)
                pendingShow.removeAll()
            }
            // Pixels outside the rects are stale in the shared buffer: scribble on them.
            for i in 0 ..< w * h where Int.random(in: 0 ..< 50, using: &rng) == 0 { frame[i] = 0xDEAD_BEEF }
        }
    }

    private func assertEqual(_ surface: IOSurface, _ reference: [UInt32], w: Int, h: Int, step: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let rowPixels = surface.bytesPerRow / 4
        let p = surface.baseAddress.assumingMemoryBound(to: UInt32.self)
        for y in 0 ..< h { for x in 0 ..< w where p[y * rowPixels + x] != reference[y * w + x] {
            XCTFail("step \(step): pixel (\(x),\(y)) differs", file: file, line: line)
            return
        } }
    }
}
