import Foundation
import Testing
@testable import ScanCore

@Suite("Directory readers")
struct DirectoryReaderTests {
    /// Builds a directory holding one of each thing a reader has to classify.
    static func makeFixture() throws -> URL {
        let root = URL.temporaryDirectory.appending(path: "tortu-fixture-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        try Data(repeating: 0x41, count: 10_000)
            .write(to: root.appending(path: "ten-thousand.bin"))
        try Data().write(to: root.appending(path: "empty.bin"))
        try Data(repeating: 0x42, count: 3)
            .write(to: root.appending(path: "üç-bayt.txt"))
        try manager.createDirectory(
            at: root.appending(path: "nested"), withIntermediateDirectories: false
        )
        try manager.createSymbolicLink(
            at: root.appending(path: "link"),
            withDestinationURL: root.appending(path: "ten-thousand.bin")
        )
        return root
    }

    @Test("Both readers see the same directory")
    func readersAgree() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let path = fixture.path(percentEncoded: false)

        let portable = try PortableDirectoryReader().entries(at: path)
            .sorted { $0.name < $1.name }
        let fast = try FastDirectoryReader().entries(at: path)
            .sorted { $0.name < $1.name }

        #expect(portable.map(\.name) == fast.map(\.name))
        #expect(portable.count == 5)

        for (slow, quick) in zip(portable, fast) {
            #expect(slow.kind == quick.kind, "kind differs for \(slow.name)")
            #expect(slow.deviceID == quick.deviceID, "device differs for \(slow.name)")
            #expect(slow.fileID == quick.fileID, "file id differs for \(slow.name)")
            #expect(
                abs(slow.modified.timeIntervalSince(quick.modified)) < 1.5,
                "modification time differs for \(slow.name)"
            )

            // File attributes are returned only for files, so sizes are
            // compared only there. A directory's own storage is read by the
            // scanner when it stats the directory, not from its parent's
            // listing.
            if slow.kind == .file {
                #expect(slow.logicalSize == quick.logicalSize, "size differs for \(slow.name)")
                #expect(
                    slow.allocatedSize == quick.allocatedSize,
                    "allocated size differs for \(slow.name)"
                )
            }
        }
    }

    @Test("Classifies each kind of entry")
    func classifiesKinds() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let entries = try FastDirectoryReader()
            .entries(at: fixture.path(percentEncoded: false))
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        #expect(byName["nested"]?.kind == .directory)
        #expect(byName["link"]?.kind == .symlink)
        #expect(byName["ten-thousand.bin"]?.kind == .file)
        #expect(byName["ten-thousand.bin"]?.logicalSize == ByteCount(10_000))
        // Allocated size rounds up to whole blocks, so it is at least the
        // logical size and usually more.
        #expect((byName["ten-thousand.bin"]?.allocatedSize ?? .zero) >= ByteCount(10_000))
        #expect(byName["empty.bin"]?.logicalSize == .zero)
        #expect(byName["üç-bayt.txt"]?.logicalSize == ByteCount(3))
    }

    @Test("Both readers agree on a directory with many entries")
    func readersAgreeAtScale() throws {
        let root = URL.temporaryDirectory.appending(path: "tortu-many-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Enough entries to force more than one getattrlistbulk round trip
        // with a small buffer, which is where a parser bug would surface.
        for index in 0 ..< 500 {
            try Data(repeating: 0x43, count: index)
                .write(to: root.appending(path: "file-\(index).bin"))
        }
        let path = root.path(percentEncoded: false)

        let portable = try PortableDirectoryReader().entries(at: path)
            .sorted { $0.name < $1.name }
        let fast = try FastDirectoryReader(bufferSize: 8 * 1024).entries(at: path)
            .sorted { $0.name < $1.name }

        #expect(portable.count == 500)
        #expect(fast.count == 500)
        #expect(portable.map(\.name) == fast.map(\.name))
        #expect(portable.map(\.allocatedSize) == fast.map(\.allocatedSize))
        #expect(portable.map(\.fileID) == fast.map(\.fileID))
    }

    @Test("A missing directory is reported, not ignored")
    func missingDirectory() {
        #expect(throws: ScanError.self) {
            try FastDirectoryReader().entries(at: "/no/such/dir/\(UUID().uuidString)")
        }
        #expect(throws: ScanError.self) {
            try PortableDirectoryReader().entries(at: "/no/such/dir/\(UUID().uuidString)")
        }
    }
}

@Suite("Mount points in directory listings")
struct MountListingTests {
    /// Pins a difference that silently broke the scanner once.
    ///
    /// `getattrlistbulk` reads a directory's own records and does not resolve
    /// a filesystem mounted over a child, so it reports the covered
    /// directory's device. `fstatat` does resolve it. Neither is wrong, but a
    /// scanner that took the boundary decision from bulk attributes would
    /// happily walk into every mount on the machine.
    @Test("The two readers disagree about a mount point's device")
    func readersDisagreeOnMounts() throws {
        let rootDevice = try MountTable.deviceID(of: "/")
        let devfsDevice = try MountTable.deviceID(of: "/dev")
        try #require(rootDevice != devfsDevice)

        let fast = try #require(
            FastDirectoryReader().entries(at: "/").first { $0.name == "dev" }
        )
        let portable = try #require(
            PortableDirectoryReader().entries(at: "/").first { $0.name == "dev" }
        )

        #expect(fast.deviceID == rootDevice, "bulk attributes report the covered directory")
        #expect(portable.deviceID == devfsDevice, "fstatat resolves the mount")

        // Which is why the scanner stats a directory itself before descending.
        let boundary = try ScanBoundary(rootPath: "/")
        #expect(try boundary.isBoundary(path: "/dev"))
    }
}
