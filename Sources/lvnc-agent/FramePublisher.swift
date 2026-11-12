import CoreVideo
import Foundation
import LVNCCore

/// Turns captured frames into shared-memory buffers + dirty rects for the viewer.
///
/// Keeps a copy of the last frame and diffs incoming frames against it in 64x64 tiles.
/// Changed tiles accumulate in `pending` until a buffer is free (the viewer released it);
/// then only those tiles are copied into the buffer and announced. So a slow viewer
/// just gets fewer, larger updates, never stale pixels.
final class FramePublisher {
    private let layout: FrameLayout
    private let region: SharedRegion
    private let queue = DispatchQueue(label: "lvnc.publisher")

    private let tile = 64
    private let tilesX: Int
    private let tilesY: Int

    // Only touched on `queue`.
    private let last: UnsafeMutableRawPointer
    private var pending: [Bool]
    private var held: [Bool]
    private var connection: Connection?
    private var haveFrame = false
    private var seq: UInt64 = 0

    private var stats = PublishStats()

    init(layout: FrameLayout, region: SharedRegion) {
        self.layout = layout
        self.region = region
        tilesX = (layout.width + tile - 1) / tile
        tilesY = (layout.height + tile - 1) / tile
        last = UnsafeMutableRawPointer.allocate(byteCount: layout.stride * layout.height, alignment: 64)
        last.initializeMemory(as: UInt8.self, repeating: 0, count: layout.stride * layout.height)
        pending = Array(repeating: false, count: tilesX * tilesY)
        held = Array(repeating: false, count: layout.bufferCount)
    }

    deinit { last.deallocate() }

    /// New viewer: everything is pending, all buffers free.
    func attach(_ c: Connection) {
        queue.sync {
            connection = c
            for i in held.indices { held[i] = false }
            for i in pending.indices { pending[i] = true }
            stats = PublishStats()
            flush()
        }
    }

    func detach(_ c: Connection) {
        queue.sync {
            if connection === c { connection = nil }
        }
    }

    func release(_ buffer: UInt32) {
        queue.async {
            let i = Int(buffer)
            guard i < self.held.count else { return }
            self.held[i] = false
            self.flush()
        }
    }

    /// Called synchronously from the capture callback. Changed tiles are found on the GPU
    /// when possible, else by comparing on the CPU. `changed` (ScreenCaptureKit's dirty rects)
    /// is not trusted, only checked against what really changed (stats: "missed").
    func submit(base: UnsafeRawPointer, stride: Int, width: Int, height: Int,
                changed: [CGRect]?, pixelBuffer: CVPixelBuffer?) {
        queue.sync {
            let w = min(width, layout.width), h = min(height, layout.height)
            let started = DispatchTime.now()
            let changedTiles: [Int]
            if let gpu, let pixelBuffer, let tiles = gpu.changedTiles(pixelBuffer) {
                // The GPU keeps the frame; flush() copies from there.
                for index in tiles { pending[index] = true }
                changedTiles = tiles
                latestOnGPU = true
            } else {
                // `last` may be behind after GPU frames; comparing against it still finds every
                // tile that differs from this frame and brings it up to date.
                gpu?.invalidate()
                changedTiles = diff(base: base, stride: stride, width: w, height: h)
                latestOnGPU = false
            }
            stats.captured(diffNanos: DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds)
            if let changed {
                let mask = tileMask(changed, width: w, height: h)
                stats.dirtyRects(marked: mask.reduce(0) { $0 + ($1 ? 1 : 0) }, changed: changedTiles.count,
                                 missed: changedTiles.filter { !mask[$0] }.count)
            } else {
                stats.noDirtyRects()
            }
            haveFrame = true
            flush()
        }
    }

    /// Lazily: the first frame tells whether the GPU path applies at all.
    private lazy var gpu: GPUTileDiffer? = GPUTileDiffer(width: layout.width, height: layout.height, tile: tile, region: region)
    /// The newest frame was compared on the GPU, so its pixels are there, not in `last`.
    private var latestOnGPU = false

    /// Tiles touched by any of the rects.
    private func tileMask(_ rects: [CGRect], width: Int, height: Int) -> [Bool] {
        var mask = Array(repeating: false, count: tilesX * tilesY)
        for r in rects {
            let x0 = max(0, Int(r.minX.rounded(.down))), y0 = max(0, Int(r.minY.rounded(.down)))
            let x1 = min(width, Int(r.maxX.rounded(.up))), y1 = min(height, Int(r.maxY.rounded(.up)))
            guard x1 > x0, y1 > y0 else { continue }
            for ty in (y0 / tile) ... ((y1 - 1) / tile) {
                for tx in (x0 / tile) ... ((x1 - 1) / tile) { mask[ty * tilesX + tx] = true }
            }
        }
        return mask
    }

    /// Returns the indices of tiles that differ from the last frame.
    @discardableResult
    private func diff(base: UnsafeRawPointer, stride: Int, width: Int, height: Int) -> [Int] {
        var changed: [Int] = []
        let ls = layout.stride
        for ty in 0 ..< tilesY {
            let y0 = ty * tile
            if y0 >= height { break }
            let ch = min(tile, height - y0)
            for tx in 0 ..< tilesX {
                let x0 = tx * tile
                if x0 >= width { break }
                let rowBytes = min(tile, width - x0) * 4
                var dirty = false
                for y in y0 ..< y0 + ch {
                    let src = base + y * stride + x0 * 4
                    let dst = last + y * ls + x0 * 4
                    if dirty || memcmp(src, dst, rowBytes) != 0 {
                        dirty = true
                        memcpy(dst, src, rowBytes)
                    }
                }
                if dirty {
                    pending[ty * tilesX + tx] = true
                    changed.append(ty * tilesX + tx)
                }
            }
        }
        return changed
    }

    /// Copy pending tiles into a free buffer and announce them. Runs on `queue`.
    private func flush() {
        guard haveFrame, let c = connection, pending.contains(true) else { return }
        guard let index = held.firstIndex(of: false) else {
            stats.waitedForBuffer += 1 // the viewer still holds all buffers
            return
        }

        var rects: [Rect] = []
        var tiles = 0
        for ty in 0 ..< tilesY {
            let y0 = ty * tile
            let h = min(tile, layout.height - y0)
            var tx = 0
            while tx < tilesX {
                guard pending[ty * tilesX + tx] else { tx += 1; continue }
                let start = tx
                while tx < tilesX && pending[ty * tilesX + tx] {
                    pending[ty * tilesX + tx] = false
                    tx += 1
                }
                tiles += tx - start
                let x = start * tile
                rects.append(Rect(x: x, y: y0, w: min(tx * tile, layout.width) - x, h: h))
            }
        }

        let offset = layout.offset(ofBuffer: index)
        if latestOnGPU {
            guard let gpu, gpu.copyOut(rects, offset: offset, stride: layout.stride) else {
                // Should not happen; drop the GPU and resend everything from the next frame.
                lvncLog("gpu", "copy failed, continuing on the CPU")
                gpu = nil
                latestOnGPU = false
                haveFrame = false
                for i in pending.indices { pending[i] = true }
                return
            }
        } else {
            let dst = region.base + offset
            let ls = layout.stride
            for r in rects {
                for y in Int(r.y) ..< Int(r.y + r.h) {
                    memcpy(dst + y * ls + Int(r.x) * 4, last + y * ls + Int(r.x) * 4, Int(r.w) * 4)
                }
            }
        }

        held[index] = true
        seq += 1
        do {
            try c.send(.frame(FrameMsg(buffer: UInt32(index), seq: seq, rects: rects)))
        } catch {
            connection = nil // the session's reader notices the broken socket and cleans up
            return
        }

        stats.sent(tiles: tiles)
        if let line = stats.report(totalTiles: tilesX * tilesY) { lvncLog("publish", line) }
    }
}

/// Every 10 s: what the capture delivered, what it cost, what was sent, the best second.
private struct PublishStats {
    private var since = DispatchTime.now()
    private var frames = 0, diffNanos: UInt64 = 0, maxDiffNanos: UInt64 = 0
    private var updates = 0, tiles = 0
    var waitedForBuffer = 0
    private var secondStart = DispatchTime.now(), secondUpdates = 0, peakPerSecond = 0

    private var withRects = 0, withoutRects = 0, marked = 0, changedTiles = 0, missed = 0

    mutating func dirtyRects(marked m: Int, changed c: Int, missed x: Int) {
        withRects += 1; marked += m; changedTiles += c; missed += x
    }

    mutating func noDirtyRects() { withoutRects += 1 }

    mutating func captured(diffNanos nanos: UInt64) {
        frames += 1
        diffNanos += nanos
        maxDiffNanos = max(maxDiffNanos, nanos)
    }

    mutating func sent(tiles count: Int) {
        updates += 1
        tiles += count
        let now = DispatchTime.now()
        if now.uptimeNanoseconds - secondStart.uptimeNanoseconds >= 1_000_000_000 {
            secondStart = now
            secondUpdates = 0
        }
        secondUpdates += 1
        peakPerSecond = max(peakPerSecond, secondUpdates)
    }

    mutating func report(totalTiles: Int) -> String? {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1e9
        guard elapsed >= 10 else { return nil }
        defer { self = PublishStats() }
        let main = String(format: "captured %.1f/s (diff avg %.1f ms, max %.1f) -> sent %.1f/s, peak %d/s, avg %.0f of %d tiles, waited for buffer %d×",
                          Double(frames) / elapsed, Double(diffNanos) / Double(max(1, frames)) / 1e6, Double(maxDiffNanos) / 1e6,
                          Double(updates) / elapsed, peakPerSecond, Double(tiles) / Double(max(1, updates)), totalTiles, waitedForBuffer)
        let rects = String(format: " | dirty rects in %d/%d frames: marked avg %.0f tiles, really changed avg %.0f, missed %d",
                           withRects, withRects + withoutRects, Double(marked) / Double(max(1, withRects)),
                           Double(changedTiles) / Double(max(1, withRects)), missed)
        return main + rects
    }

}
