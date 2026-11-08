import Foundation
import Testing
@testable import ScanCore

@Suite("Directory scanner")
struct DirectoryScannerTests {
    /// A tree of known shape: 3 files at the root, a nested directory with 2
    /// more, and an empty directory.
    static func makeTree() throws -> URL {
        let manager = FileManager.default
        let root = URL.temporaryDirectory.appending(path: "tortu-scan-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        for index in 1 ... 3 {
            try Data(repeating: 0x41, count: index * 1_000)
                .write(to: root.appending(path: "root-\(index).bin"))
        }
        let nested = root.appending(path: "nested")
        try manager.createDirectory(at: nested, withIntermediateDirectories: false)
        for index in 1 ... 2 {
            try Data(repeating: 0x42, count: index * 2_000)
                .write(to: nested.appending(path: "nested-\(index).bin"))
        }
        try manager.createDirectory(
            at: root.appending(path: "empty"), withIntermediateDirectories: false
        )
        return root
    }

    @Test("Counts every file in the tree")
    func countsFiles() async throws {
        let tree = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }

        let result = try await DirectoryScanner().scan(root: tree)
        #expect(result.root.fileCount == 5)
        #expect(result.directoriesVisited == 3)  // root, nested, empty
        #expect(result.unreadablePaths.isEmpty)
        #expect(result.root.totalSize > ByteCount(11_000))
    }

    @Test("A parent's total includes its children")
    func totalsRollUp() async throws {
        let tree = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }

        let result = try await DirectoryScanner().scan(root: tree)
        let nested = try #require(result.root.children.first { $0.name == "nested" })
        #expect(nested.fileCount == 2)
        #expect(nested.totalSize > ByteCount(6_000))
        #expect(result.root.totalSize > nested.totalSize)
    }

    @Test("Both readers produce the same measurement")
    func readersMeasureAlike() async throws {
        let tree = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }

        let fast = try await DirectoryScanner(reader: FastDirectoryReader()).scan(root: tree)
        let portable = try await DirectoryScanner(reader: PortableDirectoryReader())
            .scan(root: tree)

        #expect(fast.root.totalSize == portable.root.totalSize)
        #expect(fast.root.fileCount == portable.root.fileCount)
        #expect(fast.directoriesVisited == portable.directoriesVisited)
    }

    @Test("A hard link is counted once")
    func hardLinkCountedOnce() async throws {
        let manager = FileManager.default
        let root = URL.temporaryDirectory.appending(path: "tortu-link-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let original = root.appending(path: "original.bin")
        try Data(repeating: 0x43, count: 50_000).write(to: original)
        try manager.linkItem(at: original, to: root.appending(path: "hardlink.bin"))

        let result = try await DirectoryScanner().scan(root: root)
        #expect(result.hardLinksSkipped == 1)
        // Both names are listed, but the bytes are only counted for one.
        #expect(result.root.children.count == 2)
        #expect(result.root.children.filter(\.sharesStorage).count == 1)
        #expect(result.root.totalSize < ByteCount(100_000))
        #expect(result.root.totalSize >= ByteCount(50_000))
    }

    @Test("The walk stops at a filesystem boundary")
    func stopsAtBoundary() async throws {
        // /dev is devfs and is always a different filesystem from /.
        let result = try await DirectoryScanner(options: ScanOptions(maxDepth: 2))
            .scan(rootPath: "/")

        let dev = try #require(result.root.children.first { $0.name == "dev" })
        #expect(dev.isBoundary)
        #expect(dev.totalSize == .zero)
        #expect(result.boundariesStopped.contains("/dev"))
    }

    @Test("Depth limiting stops the walk")
    func respectsMaxDepth() async throws {
        let tree = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }

        let shallow = try await DirectoryScanner(options: ScanOptions(maxDepth: 1))
            .scan(root: tree)
        let nested = try #require(shallow.root.children.first { $0.name == "nested" })
        #expect(nested.children.isEmpty)
        #expect(shallow.root.fileCount == 3)
    }

    @Test("Progress is reported during a scan")
    func reportsProgress() async throws {
        let tree = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }

        final class Box: @unchecked Sendable {
            var reports: [ScanProgress] = []
            let lock = NSLock()
            func add(_ report: ScanProgress) {
                lock.lock(); defer { lock.unlock() }
                reports.append(report)
            }
        }
        let box = Box()
        _ = try await DirectoryScanner(options: ScanOptions(progressInterval: 1))
            .scan(root: tree) { box.add($0) }

        #expect(!box.reports.isEmpty)
        #expect(box.reports.allSatisfy { !$0.currentPath.isEmpty })
    }

    @Test("Children can be ordered largest first")
    func ordersBySize() async throws {
        let tree = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }

        let result = try await DirectoryScanner().scan(root: tree)
        let ordered = result.root.childrenBySize.map(\.totalSize)
        #expect(ordered == ordered.sorted(by: >))
    }
}
