import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import Metal

/// The remote screen as a few IOSurfaces that CoreAnimation shows directly (no copy, no
/// texture upload of the whole screen). Only changed rectangles are written.
///
/// A surface cannot be written while it is on screen, nor right after being replaced (the
/// render server may still be compositing with it), so frames rotate through four of them. Each surface remembers which areas changed since it was last written ("stale");
/// before receiving a new frame it first catches up on those from the newest surface.
///
/// With a shared-memory region and a Metal device, all copying is done by the GPU: the
/// region is a no-copy MTLBuffer, the surfaces are IOSurface-backed textures. Otherwise the
/// CPU copies.
public final class SurfaceChain {
    private struct Slot {
        let surface: IOSurface
        var stale: [Rect] = []
        var fullyStale = false
        var lastShown = 0
    }

    public let width: Int
    public let height: Int
    private var slots: [Slot]
    private var newest: Int?          // reader thread only
    private let lock = NSLock()       // guards `recentlyShown` and `showCounter`
    private var recentlyShown: [Int] = [] // the one on screen and the one before it
    private var showCounter = 0

    /// Above this many stale rectangles a surface just copies everything.
    private let maxStaleRects = 64

    /// GPU path (nil: CPU copies).
    private struct GPU {
        let queue: MTLCommandQueue
        let source: MTLBuffer          // the whole shared-memory region, no copy
        let sourceBase: UnsafeRawPointer
        let textures: [MTLTexture]     // one per slot, backed by its IOSurface
    }
    private var gpu: GPU?
    public var usesGPU: Bool { gpu != nil }

    /// `region`: the shared memory frames are read from; enables the GPU path.
    public init(width: Int, height: Int, count: Int = 4, region: SharedRegion? = nil) throws {
        self.width = width
        self.height = height
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList()
        slots = try (0 ..< count).map { _ in
            guard let surface = IOSurface(properties: [
                .width: width, .height: height, .bytesPerElement: 4,
                .pixelFormat: kCVPixelFormatType_32BGRA,
            ]) else { throw WireError.protocolError("cannot create IOSurface \(width)x\(height)") }
            if let sRGB { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, sRGB) }
            Self.fill(surface, gray: 0x1A)
            return Slot(surface: surface)
        }
        if let region { gpu = Self.makeGPU(region: region, surfaces: slots.map(\.surface), width: width, height: height) }
    }

    private static func makeGPU(region: SharedRegion, surfaces: [IOSurface], width: Int, height: Int) -> GPU? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let source = device.makeBuffer(bytesNoCopy: region.base, length: region.size,
                                             options: .storageModeShared, deallocator: nil)
        else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        var textures: [MTLTexture] = []
        for surface in surfaces {
            guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return nil }
            textures.append(texture)
        }
        return GPU(queue: queue, source: source, sourceBase: UnsafeRawPointer(region.base), textures: textures)
    }

    /// Reader thread: write a frame's rectangles from shared memory; returns the surface to show.
    public func apply(_ rects: [Rect], from source: UnsafeRawPointer, sourceStride: Int) -> IOSurface {
        let target = pickTarget()
        if let gpu, gpuCopy(gpu, rects, sourceOffset: source - gpu.sourceBase, sourceStride: sourceStride, target: target) {
            return finish(rects, target: target)
        }

        slots[target].surface.lock(options: [], seed: nil)
        let dst = slots[target].surface.baseAddress
        let dstStride = slots[target].surface.bytesPerRow

        // Catch up on what changed since this surface was last written.
        if let newest, newest != target, slots[target].fullyStale || !slots[target].stale.isEmpty {
            let src = slots[newest].surface
            src.lock(options: .readOnly, seed: nil)
            let catchUp = slots[target].fullyStale ? [Rect(x: 0, y: 0, w: width, h: height)] : slots[target].stale
            copy(catchUp, from: UnsafeRawPointer(src.baseAddress), stride: src.bytesPerRow, to: dst, stride: dstStride)
            src.unlock(options: .readOnly, seed: nil)
        }
        copy(rects, from: source, stride: sourceStride, to: dst, stride: dstStride)
        slots[target].surface.unlock(options: [], seed: nil)
        return finish(rects, target: target)
    }

    /// Catch-up and new rects as GPU blits; waits for them. false: fall back to the CPU.
    private func gpuCopy(_ gpu: GPU, _ rects: [Rect], sourceOffset: Int, sourceStride: Int, target: Int) -> Bool {
        guard sourceOffset >= 0, sourceOffset + sourceStride * height <= gpu.source.length,
              let commands = gpu.queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else { return false }
        let dst = gpu.textures[target]

        if let newest, newest != target, slots[target].fullyStale || !slots[target].stale.isEmpty {
            let src = gpu.textures[newest]
            let catchUp = slots[target].fullyStale ? [Rect(x: 0, y: 0, w: width, h: height)] : slots[target].stale
            for r in catchUp where valid(r) {
                let origin = MTLOrigin(x: Int(r.x), y: Int(r.y), z: 0)
                blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin,
                          sourceSize: MTLSize(width: Int(r.w), height: Int(r.h), depth: 1),
                          to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
            }
        }
        for r in rects where valid(r) {
            blit.copy(from: gpu.source, sourceOffset: sourceOffset + Int(r.y) * sourceStride + Int(r.x) * 4,
                      sourceBytesPerRow: sourceStride, sourceBytesPerImage: sourceStride * Int(r.h),
                      sourceSize: MTLSize(width: Int(r.w), height: Int(r.h), depth: 1),
                      to: dst, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: Int(r.x), y: Int(r.y), z: 0))
        }
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return commands.status == .completed
    }

    private func valid(_ r: Rect) -> Bool {
        r.w > 0 && r.h > 0 && Int(r.x) + Int(r.w) <= width && Int(r.y) + Int(r.h) <= height
    }

    /// Bookkeeping after `target` received `rects`.
    private func finish(_ rects: [Rect], target: Int) -> IOSurface {
        slots[target].stale = []
        slots[target].fullyStale = false
        for i in slots.indices where i != target && !slots[i].fullyStale {
            if slots[i].stale.count + rects.count > maxStaleRects {
                slots[i].stale = []
                slots[i].fullyStale = true
            } else {
                slots[i].stale += rects
            }
        }
        newest = target
        return slots[target].surface
    }

    /// Main thread: the surface just put on screen.
    public func didShow(_ surface: IOSurface) {
        lock.lock(); defer { lock.unlock() }
        guard let i = slots.firstIndex(where: { $0.surface === surface }) else { return }
        showCounter += 1
        slots[i].lastShown = showCounter
        recentlyShown.removeAll { $0 == i }
        recentlyShown.insert(i, at: 0)
        if recentlyShown.count > 2 { recentlyShown.removeLast() }
    }

    /// Not the one on screen or the one before it, not the newest (it may be shown any
    /// moment); of the rest the one shown longest ago.
    private func pickTarget() -> Int {
        lock.lock(); defer { lock.unlock() }
        let candidates = slots.indices.filter { !recentlyShown.contains($0) && $0 != newest }
        return candidates.min { slots[$0].lastShown < slots[$1].lastShown }
            ?? slots.indices.first { $0 != recentlyShown.first && $0 != newest } ?? 0
    }

    private func copy(_ rects: [Rect], from src: UnsafeRawPointer, stride srcStride: Int,
                      to dst: UnsafeMutableRawPointer, stride dstStride: Int) {
        for r in rects {
            let x = Int(r.x), y = Int(r.y), w = Int(r.w), h = Int(r.h)
            guard w > 0, h > 0, x + w <= width, y + h <= height else { continue }
            for row in y ..< y + h {
                memcpy(dst + row * dstStride + x * 4, src + row * srcStride + x * 4, w * 4)
            }
        }
    }

    private static func fill(_ surface: IOSurface, gray: UInt8) {
        surface.lock(options: [], seed: nil)
        let p = surface.baseAddress.assumingMemoryBound(to: UInt32.self)
        let pixel = UInt32(0xFF00_0000) | UInt32(gray) << 16 | UInt32(gray) << 8 | UInt32(gray)
        let count = surface.bytesPerRow / 4 * surface.height
        p.update(repeating: pixel, count: count)
        surface.unlock(options: [], seed: nil)
    }
}
