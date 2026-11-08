import Foundation

public enum EntryKind: Sendable, Hashable {
    case file
    case directory
    case symlink
    case other

    init(mode: mode_t) {
        switch mode & S_IFMT {
        case S_IFDIR: self = .directory
        case S_IFREG: self = .file
        case S_IFLNK: self = .symlink
        default: self = .other
        }
    }

    /// `vtype` arrives in Swift as a struct wrapping a raw value rather than
    /// as an integer, so the comparison goes through `rawValue`.
    init(objectType: fsobj_type_t) {
        switch objectType {
        case fsobj_type_t(VDIR.rawValue): self = .directory
        case fsobj_type_t(VREG.rawValue): self = .file
        case fsobj_type_t(VLNK.rawValue): self = .symlink
        default: self = .other
        }
    }
}

/// One entry in a directory, with everything a scan needs read in a single
/// pass so that no second `stat` is required.
public struct DirectoryEntry: Sendable, Hashable {
    public let name: String
    public let kind: EntryKind

    /// Identifies the filesystem this entry lives on. A value different from
    /// the scan root's means the entry is a mount and must not be descended
    /// into.
    public let deviceID: dev_t

    /// Inode number. Combined with `deviceID` it identifies physical storage,
    /// which is how hard links and APFS clones are kept from being counted
    /// more than once.
    public let fileID: UInt64

    /// What the file claims to be.
    public let logicalSize: ByteCount

    /// What the file actually occupies. This is the number that changes when
    /// the file is removed, so it is the one Tortu reports.
    public let allocatedSize: ByteCount

    public let modified: Date

    public init(
        name: String,
        kind: EntryKind,
        deviceID: dev_t,
        fileID: UInt64,
        logicalSize: ByteCount,
        allocatedSize: ByteCount,
        modified: Date
    ) {
        self.name = name
        self.kind = kind
        self.deviceID = deviceID
        self.fileID = fileID
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modified = modified
    }

    /// Identity of the underlying storage, not of the path. Two hard links to
    /// one file share this.
    public var storageIdentity: StorageIdentity {
        StorageIdentity(deviceID: deviceID, fileID: fileID)
    }
}

public struct StorageIdentity: Sendable, Hashable {
    public let deviceID: dev_t
    public let fileID: UInt64

    public init(deviceID: dev_t, fileID: UInt64) {
        self.deviceID = deviceID
        self.fileID = fileID
    }
}

/// Reads the immediate children of a directory.
public protocol DirectoryReading: Sendable {
    func entries(at path: String) throws -> [DirectoryEntry]
}
