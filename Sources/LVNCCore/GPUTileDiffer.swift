import CoreVideo
import Foundation
import Metal

/// Finds changed 64×64 tiles on the GPU.
///
/// The captured frame (an IOSurface-backed pixel buffer) becomes a Metal texture without a
/// copy; a compute kernel compares it with the previous frame, kept on the GPU, and raises a
/// flag per changed tile; a blit then makes the new frame the previous one. The CPU only
/// reads the flags. Frames the GPU cannot take (no IOSurface, unexpected size) go through the
/// CPU path; after that `invalidate()` makes the next GPU frame report every tile.
public final class GPUTileDiffer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let previous: MTLTexture
    private let flags: MTLBuffer
    private var output: MTLBuffer?   // the shared-memory region, no copy
    private let width: Int
    private let height: Int
    private let tile: Int
    private let tilesX: Int
    private let tileCount: Int
    private var primed = false

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void tileDiff(texture2d<half, access::read> current  [[texture(0)]],
                         texture2d<half, access::read> previous [[texture(1)]],
                         device atomic_uint *flags              [[buffer(0)]],
                         constant uint2 &tileInfo               [[buffer(1)]], // tile size, tiles per row
                         uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= current.get_width() || gid.y >= current.get_height()) return;
        if (any(current.read(gid) != previous.read(gid))) {
            uint t = (gid.y / tileInfo.x) * tileInfo.y + gid.x / tileInfo.x;
            if (atomic_load_explicit(&flags[t], memory_order_relaxed) == 0)
                atomic_store_explicit(&flags[t], 1u, memory_order_relaxed);
        }
    }
    """

    /// `region`: shared memory to copy changed tiles into (see `copyOut`).
    public init?(width: Int, height: Int, tile: Int, region: SharedRegion? = nil) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            guard let function = library.makeFunction(name: "tileDiff") else { return nil }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            lvncLog("gpu", "cannot build the diff kernel: \(error)")
            return nil
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        let tilesX = (width + tile - 1) / tile
        let tileCount = tilesX * ((height + tile - 1) / tile)
        guard let previous = device.makeTexture(descriptor: descriptor),
              let flags = device.makeBuffer(length: tileCount * 4, options: .storageModeShared)
        else { return nil }

        self.device = device
        commandQueue = queue
        textureCache = cache
        self.previous = previous
        self.flags = flags
        self.width = width
        self.height = height
        self.tile = tile
        self.tilesX = tilesX
        self.tileCount = tileCount
        if let region {
            output = device.makeBuffer(bytesNoCopy: region.base, length: region.size, options: .storageModeShared, deallocator: nil)
        }
        lvncLog("gpu", "tile diff\(output != nil ? " and copy" : "") on \(device.name)")
    }

    /// The GPU's previous frame no longer matches what was published (a CPU-path frame came in).
    public func invalidate() {
        primed = false
    }

    /// Indices of changed tiles, or nil if this frame cannot be handled on the GPU.
    public func changedTiles(_ pixelBuffer: CVPixelBuffer) -> [Int]? {
        guard CVPixelBufferGetIOSurface(pixelBuffer) != nil,
              CVPixelBufferGetWidth(pixelBuffer) == width, CVPixelBufferGetHeight(pixelBuffer) == height,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else { return nil }

        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .bgra8Unorm,
                                                        width, height, 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture, let current = CVMetalTextureGetTexture(cvTexture),
              let commands = commandQueue.makeCommandBuffer()
        else { return nil }

        let wasPrimed = primed
        if wasPrimed {
            memset(flags.contents(), 0, tileCount * 4)
            guard let compute = commands.makeComputeCommandEncoder() else { return nil }
            compute.setComputePipelineState(pipeline)
            compute.setTexture(current, index: 0)
            compute.setTexture(previous, index: 1)
            compute.setBuffer(flags, offset: 0, index: 0)
            var info = SIMD2<UInt32>(UInt32(tile), UInt32(tilesX))
            compute.setBytes(&info, length: MemoryLayout<SIMD2<UInt32>>.size, index: 1)
            let group = MTLSize(width: 16, height: 16, depth: 1)
            compute.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: group)
            compute.endEncoding()
        }
        guard let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: current, to: previous) // becomes the reference for the next frame
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else {
            primed = false
            return nil
        }
        primed = true

        guard wasPrimed else { return Array(0 ..< tileCount) } // no reference yet: everything
        let p = flags.contents().assumingMemoryBound(to: UInt32.self)
        return (0 ..< tileCount).filter { p[$0] != 0 }
    }

    /// Copy these rects of the latest frame (the GPU's reference copy) into the shared
    /// region at `offset`, rows `stride` bytes apart; waits until done. false: not possible.
    public func copyOut(_ rects: [Rect], offset: Int, stride: Int) -> Bool {
        guard primed, let output, offset >= 0, offset + stride * height <= output.length,
              let commands = commandQueue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else { return false }
        for r in rects {
            let x = Int(r.x), y = Int(r.y), w = Int(r.w), h = Int(r.h)
            guard w > 0, h > 0, x + w <= width, y + h <= height else { continue }
            blit.copy(from: previous, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                      sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: output, destinationOffset: offset + y * stride + x * 4,
                      destinationBytesPerRow: stride, destinationBytesPerImage: stride * h)
        }
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return commands.status == .completed
    }
}
