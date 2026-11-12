import CLVNC
import Foundation

/// A mapped POSIX shared memory region.
public final class SharedRegion {
    public let fd: Int32
    public let base: UnsafeMutableRawPointer
    public let size: Int

    private init(fd: Int32, base: UnsafeMutableRawPointer, size: Int) {
        self.fd = fd
        self.base = base
        self.size = size
    }

    /// Fresh anonymous region (agent side). Only reachable through `fd`.
    public static func create(size: Int) throws -> SharedRegion {
        let fd = lvnc_shm_create(size)
        guard fd >= 0 else { throw WireError.io(errno) }
        do {
            return try map(fd: fd, size: size, writable: true)
        } catch {
            close(fd)
            throw error
        }
    }

    /// Map a region received from the peer (viewer side). Takes ownership of `fd`.
    public static func map(fd: Int32, size: Int, writable: Bool) throws -> SharedRegion {
        let prot = writable ? (PROT_READ | PROT_WRITE) : PROT_READ
        let p = mmap(nil, size, prot, MAP_SHARED, fd, 0)
        guard let p, p != MAP_FAILED else { throw WireError.io(errno) }
        return SharedRegion(fd: fd, base: p, size: size)
    }

    deinit {
        munmap(base, size)
        close(fd)
    }
}
