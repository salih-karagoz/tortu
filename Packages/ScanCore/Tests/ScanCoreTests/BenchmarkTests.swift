import Foundation
import Testing
@testable import ScanCore

@Suite("Benchmark", .enabled(if: ProcessInfo.processInfo.environment["TORTU_BENCHMARK"] != nil))
struct BenchmarkTests {
    @Test("Scan a real tree")
    func benchmark() async throws {
        let target = "/opt/homebrew"
        try #require(FileManager.default.fileExists(atPath: target))

        // Each reader runs twice, in both orders, so a warm page cache
        // cannot flatter whichever one happens to go second.
        let readers: [(String, any DirectoryReading)] = [
            ("getattrlistbulk", FastDirectoryReader()),
            ("readdir+fstatat", PortableDirectoryReader()),
            ("readdir+fstatat", PortableDirectoryReader()),
            ("getattrlistbulk", FastDirectoryReader()),
        ]
        for (label, reader) in readers {
            let result = try await DirectoryScanner(reader: reader).scan(rootPath: target)
            let seconds = Double(result.duration.components.seconds)
                + Double(result.duration.components.attoseconds) / 1e18
            let rounded = (seconds * 100).rounded() / 100
            print("BENCH \(label) | \(rounded) s | \(result.directoriesVisited) dizin"
                + " | \(result.entriesSeen) girdi | \(result.root.totalSize.formatted)"
                + " | \(result.hardLinksSkipped) hardlink"
                + " | \(result.unreadablePaths.count) okunamayan")
        }
    }
}
