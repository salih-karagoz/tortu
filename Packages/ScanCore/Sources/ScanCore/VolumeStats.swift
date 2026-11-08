import Foundation

/// Free and total space for the volume holding a given path.
///
/// `available` deliberately uses `f_bavail` rather than `f_bfree`, because
/// `f_bavail` excludes the reserve only root may touch and therefore matches
/// the number the user sees in `df` and in Finder.
public struct VolumeStats: Sendable, Hashable {
    public let total: ByteCount
    public let available: ByteCount
    public let mountPoint: String
    public let fileSystemType: String

    public var used: ByteCount { total - available }

    public var usedFraction: Double {
        guard total.rawValue > 0 else { return 0 }
        return Double(used.rawValue) / Double(total.rawValue)
    }

    /// Reads volume statistics for `path`.
    ///
    /// On APFS the number this returns can move without anyone deleting
    /// anything: the system reclaims purgeable space under pressure. So a
    /// reading taken before a cleanup and one taken after do not differ purely
    /// because of what Tortu removed, and the difference must be reported as
    /// measured rather than as credited to the cleanup.
    public static func forPath(_ path: String) throws -> VolumeStats {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else {
            throw ScanError.volumeUnreadable(path: path, code: errno)
        }
        let blockSize = Int64(fs.f_bsize)
        return VolumeStats(
            total: ByteCount(blocks: Int64(fs.f_blocks), blockSize: blockSize),
            available: ByteCount(blocks: Int64(fs.f_bavail), blockSize: blockSize),
            mountPoint: Self.string(from: fs.f_mntonname),
            fileSystemType: Self.string(from: fs.f_fstypename)
        )
    }

    public static func forHomeVolume() throws -> VolumeStats {
        try forPath(NSHomeDirectory())
    }

    /// Converts one of `statfs`'s fixed-size C character tuples to a String.
    static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
