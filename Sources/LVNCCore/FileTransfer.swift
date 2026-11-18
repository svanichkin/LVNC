import CLVNC
import Foundation

/// Files and folders handed to the peer by descriptor (clipboard copies, drag and drop).
///
/// The sender opens every regular file and passes the descriptors; the receiver clones them
/// (APFS, instant) into its own folder. No size limit, nothing large goes through the socket.
public enum FileTransfer {
    /// Files per transfer (each is one descriptor in a single message).
    public static let maxFiles = Int(LVNC_MAX_FDS)

    /// Open every regular file under `urls` and list it in `message`.
    /// false (with a log line) if nothing should be sent; the caller closes `message`'s fds either way.
    public static func collect(_ urls: [URL], into message: inout ClipboardMsg, tag: String) -> Bool {
        func addFile(_ path: String, as relative: String, size: UInt64) -> Bool {
            guard message.fds.count < maxFiles else {
                lvncLog(tag, "more than \(maxFiles) files, not shared")
                return false
            }
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else {
                lvncLog(tag, "cannot open \(relative): \(String(cString: strerror(errno)))")
                return true // skip just this one
            }
            message.fds.append(fd)
            message.files.append(.init(path: relative, isDirectory: false, size: size))
            return true
        }

        for url in urls {
            let top = url.lastPathComponent
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if !isDir.boolValue {
                let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                guard addFile(url.path, as: top, size: (attrs[.size] as? UInt64) ?? 0) else { return false }
                continue
            }

            message.files.append(.init(path: top, isDirectory: true, size: 0))
            guard let walker = FileManager.default.enumerator(atPath: url.path) else { continue }
            while let relative = walker.nextObject() as? String {
                let attrs = walker.fileAttributes ?? [:]
                let type = attrs[.type] as? FileAttributeType
                let path = "\(top)/\(relative)"
                if type == .typeDirectory {
                    message.files.append(.init(path: path, isDirectory: true, size: 0))
                } else if type == .typeRegular {
                    let size = (attrs[.size] as? UInt64) ?? 0
                    guard addFile(url.appendingPathComponent(relative).path, as: path, size: size) else { return false }
                } // symlinks and special files are skipped
            }
        }
        return !message.files.isEmpty
    }

    /// Recreate the message's files/folders in a fresh folder under `root`, keeping only the
    /// `keep` newest earlier ones (an app may still be reading them). Returns the top-level URLs.
    /// Does not close the message's descriptors.
    public static func materialize(_ message: ClipboardMsg, under root: URL, keep: Int) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let old = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let byAge = old.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
        for url in byAge.dropFirst(keep) { try? fm.removeItem(at: url) }

        let drop = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: drop, withIntermediateDirectories: true)

        var tops: [URL] = []
        var topNames: [String: String] = [:] // sender's top-level name -> ours (deduplicated)
        var usedTops = Set<String>()
        var fdIndex = 0

        for entry in message.files {
            var parts = entry.path.split(separator: "/", omittingEmptySubsequences: true).map { sanitize(String($0)) }
            guard let first = parts.first else { continue }
            // A top-level entry gets a fresh unique name; its contents (which follow it) reuse it.
            if parts.count == 1 || topNames[first] == nil {
                topNames[first] = uniqueName(first, used: &usedTops)
            }
            parts[0] = topNames[first]!
            let url = parts.reduce(drop) { $0.appendingPathComponent($1) }
            if parts.count == 1 { tops.append(url) }

            if entry.isDirectory {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            guard fdIndex < message.fds.count else { throw WireError.protocolError("missing descriptor for \(entry.path)") }
            let fd = message.fds[fdIndex]
            fdIndex += 1
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if lvnc_clone_fd_to(fd, url.path) != 0 {
                throw WireError.io(errno)
            }
        }
        return tops
    }

    /// "3 files in 1 folders (12.5 MB)"
    public static func describe(_ files: [ClipboardMsg.FileEntry]) -> String {
        let regular = files.filter { !$0.isDirectory }
        let bytes = regular.reduce(UInt64(0)) { $0 + $1.size }
        let folders = files.count - regular.count
        return "\(regular.count) files" + (folders > 0 ? " in \(folders) folders" : "")
            + String(format: " (%.1f MB)", Double(bytes) / 1_048_576)
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
    }

    private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var n = 2
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            n += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}
