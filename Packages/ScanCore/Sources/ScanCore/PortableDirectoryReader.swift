import Foundation

/// A straightforward `readdir` plus `fstatat` reader.
///
/// This is the reference implementation: slower than `getattrlistbulk` because
/// it makes one syscall per entry, but simple enough to be obviously correct.
/// `FastDirectoryReader` is checked against it in the tests.
public struct PortableDirectoryReader: DirectoryReading {
    public init() {}

    public func entries(at path: String) throws -> [DirectoryEntry] {
        guard let handle = opendir(path) else {
            throw ScanError.pathUnreadable(path: path, code: errno)
        }
        defer { closedir(handle) }

        let descriptor = dirfd(handle)
        var results: [DirectoryEntry] = []

        while let pointer = readdir(handle) {
            let name = Self.name(from: pointer.pointee.d_name)
            if name == "." || name == ".." { continue }

            var info = stat()
            // AT_SYMLINK_NOFOLLOW keeps a symlink from reporting its target's
            // device, which would let a walk leave the volume unnoticed.
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                continue
            }

            results.append(
                DirectoryEntry(
                    name: name,
                    kind: EntryKind(mode: info.st_mode),
                    deviceID: info.st_dev,
                    fileID: UInt64(info.st_ino),
                    logicalSize: ByteCount(Int64(info.st_size)),
                    allocatedSize: ByteCount(blocks: Int64(info.st_blocks), blockSize: 512),
                    modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                )
            )
        }
        return results
    }

    static func name<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
