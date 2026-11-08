import Foundation

/// One mounted filesystem, as reported by `getfsstat`.
public struct MountPoint: Sendable, Hashable {
    public let path: String
    public let fileSystemType: String
    public let isLocal: Bool
    public let isReadOnly: Bool

    /// True for the synthetic filesystems that make remote or virtual content
    /// look like ordinary directories. `devicefs` is the one that matters most
    /// here: Xcode mounts a paired iPhone under
    /// `~/Library/Developer/CoreDevice/DeviceFS`, and anything that walks into
    /// it is measuring the phone, not the Mac.
    public var isSynthetic: Bool {
        Self.syntheticTypes.contains(fileSystemType)
    }

    static let syntheticTypes: Set<String> = [
        "devicefs", "nfs", "smbfs", "afpfs", "webdav", "fuse", "osxfuse"
    ]
}

public enum MountTable {
    /// Every filesystem currently mounted.
    ///
    /// Uses `getfsstat` rather than `getmntinfo`, because `getmntinfo` returns
    /// a pointer into a shared static buffer and is unsafe to call from more
    /// than one thread.
    ///
    /// Note that `statfs` names both a struct and a function on Darwin, so the
    /// buffer is allocated through `statfs.self` rather than written as an
    /// array literal, which the compiler would read as a one-element array
    /// holding the function.
    public static func current() throws -> [MountPoint] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else {
            throw ScanError.mountTableUnavailable(code: errno)
        }

        let capacity = Int(count)
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        let byteSize = Int32(MemoryLayout<statfs>.stride * capacity)
        let written = getfsstat(buffer, byteSize, MNT_NOWAIT)
        guard written > 0 else {
            throw ScanError.mountTableUnavailable(code: errno)
        }

        var points: [MountPoint] = []
        points.reserveCapacity(Int(written))
        for index in 0 ..< Int(written) {
            points.append(makePoint(from: buffer[index]))
        }
        return points
    }

    private static func makePoint(from entry: statfs) -> MountPoint {
        let path = VolumeStats.string(from: entry.f_mntonname)
        let type = VolumeStats.string(from: entry.f_fstypename)
        let flags = entry.f_flags
        let local = (flags & UInt32(MNT_LOCAL)) != 0
        let readOnly = (flags & UInt32(MNT_RDONLY)) != 0
        return MountPoint(
            path: path,
            fileSystemType: type,
            isLocal: local,
            isReadOnly: readOnly
        )
    }

    /// The device identifier of the filesystem that `path` lives on.
    ///
    /// Uses `lstat`, so a symlink reports the device of the link itself rather
    /// than of its destination. That is what a scanner wants: following the
    /// link would otherwise walk off the volume without noticing.
    public static func deviceID(of path: String) throws -> dev_t {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw ScanError.pathUnreadable(path: path, code: errno)
        }
        return info.st_dev
    }
}
