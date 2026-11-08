import Foundation
import Testing
@testable import FindersKit
import ScanCore

@Suite("Large file finder")
struct LargeFileFinderTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func makeTree() throws -> URL {
        let root = URL.temporaryDirectory.appending(path: "tortu-large-\(UUID().uuidString)")
        let nested = root.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 300_000).write(to: root.appending(path: "big.bin"))
        try Data(repeating: 0x42, count: 10).write(to: root.appending(path: "tiny.bin"))
        try Data(repeating: 0x43, count: 200_000).write(to: nested.appending(path: "nested-big.bin"))
        return root
    }

    @Test("Finds only files above the size floor, biggest first")
    func findsLargeFiles() async throws {
        let tree = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }

        let found = try await LargeFileFinder().find(
            under: tree.path(percentEncoded: false),
            criteria: FindCriteria(minimumSize: ByteCount(100_000))
        )
        #expect(found.count == 2)
        #expect(found[0].name == "big.bin")
        #expect(found[1].name == "nested-big.bin")
        #expect(!found.contains { $0.name == "tiny.bin" })
    }

    @Test("An age filter excludes files touched recently")
    func filtersByAge() async throws {
        let tree = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }

        // The fixture was written a moment ago, so a one-day floor finds nothing.
        let found = try await LargeFileFinder().find(
            under: tree.path(percentEncoded: false),
            criteria: FindCriteria(minimumSize: ByteCount(1), untouchedFor: 86_400)
        )
        #expect(found.isEmpty)
    }

    @Test("The limit caps the result")
    func respectsLimit() async throws {
        let tree = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }

        let found = try await LargeFileFinder().find(
            under: tree.path(percentEncoded: false),
            criteria: FindCriteria(minimumSize: ByteCount(1), limit: 1)
        )
        #expect(found.count == 1)
    }
}

@Suite("Duplicate finder")
struct DuplicateFinderTests {
    static func makeTree() throws -> URL {
        let manager = FileManager.default
        let root = URL.temporaryDirectory.appending(path: "tortu-dup-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        let contents = Data(repeating: 0x41, count: 2_000_000)
        try contents.write(to: root.appending(path: "original.bin"))
        try contents.write(to: root.appending(path: "copy.bin"))

        // Same size, different contents: must not be grouped.
        var different = Data(repeating: 0x41, count: 2_000_000)
        different[1_999_999] = 0x42
        try different.write(to: root.appending(path: "lookalike.bin"))

        // Same size, same first 64 KB, different tail: catches a finder that
        // trusts the cheap prefix hash.
        var sharedPrefix = Data(repeating: 0x41, count: 2_000_000)
        sharedPrefix[1_500_000] = 0x43
        try sharedPrefix.write(to: root.appending(path: "same-prefix.bin"))

        try Data(repeating: 0x44, count: 10).write(to: root.appending(path: "small.bin"))
        return root
    }

    @Test("Groups files with identical contents")
    func groupsIdenticalFiles() async throws {
        let tree = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }

        let groups = try await DuplicateFinder().find(under: tree.path(percentEncoded: false))
        #expect(groups.count == 1)
        let names = Set(groups[0].files.map(\.name))
        #expect(names == ["copy.bin", "original.bin"])
    }

    @Test("Files that only share a prefix are not duplicates")
    func prefixCollisionIsNotAMatch() async throws {
        let tree = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }

        let groups = try await DuplicateFinder().find(under: tree.path(percentEncoded: false))
        let grouped = Set(groups.flatMap { $0.files.map(\.name) })
        #expect(!grouped.contains("same-prefix.bin"))
        #expect(!grouped.contains("lookalike.bin"))
    }

    /// The most common way a duplicate finder lies: two names for one file.
    @Test("Hard links are not offered as duplicates")
    func hardLinksAreNotDuplicates() async throws {
        let manager = FileManager.default
        let root = URL.temporaryDirectory.appending(path: "tortu-dup-link-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let original = root.appending(path: "original.bin")
        try Data(repeating: 0x45, count: 2_000_000).write(to: original)
        try manager.linkItem(at: original, to: root.appending(path: "link.bin"))

        let groups = try await DuplicateFinder().find(under: root.path(percentEncoded: false))
        #expect(groups.isEmpty, "two names for one file free nothing when one is removed")
    }

    @Test("Small files are below the floor")
    func ignoresSmallFiles() async throws {
        let tree = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }

        let finder = DuplicateFinder(
            options: .init(minimumSize: ByteCount(5_000_000))
        )
        #expect(try await finder.find(under: tree.path(percentEncoded: false)).isEmpty)
    }

    @Test("The reclaim figure keeps one copy")
    func reclaimKeepsOneCopy() {
        let group = DuplicateGroup(digest: "x", files: (0 ..< 3).map {
            FoundFile(path: "/tmp/\($0)", size: ByteCount(1_000), modified: .distantPast)
        })
        #expect(group.reclaimableUpperBound == ByteCount(2_000))
    }

    @Test("A lone file is not a group")
    func singleFileIsNotAGroup() {
        let group = DuplicateGroup(digest: "x", files: [
            FoundFile(path: "/tmp/a", size: ByteCount(1_000), modified: .distantPast)
        ])
        #expect(group.reclaimableUpperBound == .zero)
    }
}
