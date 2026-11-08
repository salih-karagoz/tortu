import Foundation
import Testing
@testable import ScanCore

@Suite("Scan boundaries")
struct ScanBoundaryTests {
    @Test("The mount table lists the root filesystem")
    func mountTableIncludesRoot() throws {
        let mounts = try MountTable.current()
        #expect(mounts.contains { $0.path == "/" })
    }

    @Test("A root does not treat itself as a boundary")
    func rootIsNotItsOwnBoundary() throws {
        let boundary = try ScanBoundary(rootPath: "/")
        #expect(try boundary.isBoundary(path: "/") == false)
    }

    /// The incident this guards against: a walk rooted at the home volume
    /// descending into a `devicefs` mount and measuring a paired iPhone.
    @Test("A filesystem of a different type is a boundary")
    func foreignFilesystemIsBoundary() throws {
        let boundary = try ScanBoundary(rootPath: "/")
        // devfs is always mounted at /dev and is never the root filesystem.
        #expect(try boundary.isBoundary(path: "/dev"))
    }

    /// Documents why the mount table alone is not a usable boundary test.
    @Test("A firmlinked data volume is not a boundary")
    func firmlinkedDataVolumeIsNotABoundary() throws {
        let dataVolume = "/System/Volumes/Data"
        try #require(FileManager.default.fileExists(atPath: dataVolume))

        let listedAsMount = try MountTable.current().contains { $0.path == dataVolume }
        #expect(listedAsMount, "the data volume should appear in the mount table")

        // ...and yet it shares the root's device identifier, because an APFS
        // volume group is one filesystem joined by firmlinks. Treating every
        // mount-table entry as a boundary would skip the user's entire home.
        let boundary = try ScanBoundary(rootPath: "/")
        #expect(try boundary.isBoundary(path: dataVolume) == false)
    }

    @Test("Synthetic filesystems are recognised by type")
    func syntheticTypes() {
        let devicefs = MountPoint(
            path: "/Users/x/Library/Developer/CoreDevice/DeviceFS",
            fileSystemType: "devicefs", isLocal: true, isReadOnly: true
        )
        let apfs = MountPoint(
            path: "/", fileSystemType: "apfs", isLocal: true, isReadOnly: true
        )
        #expect(devicefs.isSynthetic)
        #expect(!apfs.isSynthetic)
    }
}
