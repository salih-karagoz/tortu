import Foundation

/// Keeps a directory walk inside the volume it started on.
///
/// This exists because of a specific, expensive mistake. `du` was run over
/// `~/Library/Developer/CoreDevice/DeviceFS`, reported 22 GB, and that number
/// was acted on. The directory is a `devicefs` mount showing a paired
/// iPhone's filesystem; it occupies 8 KB on the Mac. The 22 GB was the phone.
/// Deleting through the mount reached the phone's own storage.
///
/// Every walk in Tortu is therefore bounded: the device identifier of the root
/// is recorded once, and any entry reporting a different one is a mount and is
/// recorded without being descended into.
///
/// The authority for that decision is `st_dev`, never the mount table. macOS
/// joins the System and Data volumes of an APFS volume group with firmlinks
/// and lists both in the mount table, yet they share one device identifier
/// because they are one filesystem to the kernel. A scanner that refused to
/// descend into every path the mount table names would skip
/// `/System/Volumes/Data`, which is where all of the user's files live.
public struct ScanBoundary: Sendable, Hashable {
    public let rootPath: String
    public let rootDeviceID: dev_t

    public init(root: URL) throws {
        try self.init(rootPath: root.path(percentEncoded: false))
    }

    public init(rootPath: String) throws {
        self.rootPath = rootPath
        self.rootDeviceID = try MountTable.deviceID(of: rootPath)
    }

    /// Whether this entry sits on a different filesystem than the scan root.
    public func isBoundary(_ entry: stat) -> Bool {
        entry.st_dev != rootDeviceID
    }

    public func isBoundary(path: String) throws -> Bool {
        try MountTable.deviceID(of: path) != rootDeviceID
    }
}
