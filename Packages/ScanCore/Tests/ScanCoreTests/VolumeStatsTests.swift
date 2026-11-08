import Foundation
import Testing
@testable import ScanCore

@Suite("VolumeStats")
struct VolumeStatsTests {
    @Test("Reports plausible figures for the home volume")
    func homeVolume() throws {
        let stats = try VolumeStats.forHomeVolume()
        #expect(stats.total > .zero)
        #expect(stats.available <= stats.total)
        #expect(stats.used.rawValue == stats.total.rawValue - stats.available.rawValue)
        #expect(stats.usedFraction >= 0 && stats.usedFraction <= 1)
        #expect(!stats.mountPoint.isEmpty)
        #expect(!stats.fileSystemType.isEmpty)
    }

    @Test("Surfaces an error for a path that does not exist")
    func missingPath() {
        #expect(throws: ScanError.self) {
            try VolumeStats.forPath("/no/such/path/\(UUID().uuidString)")
        }
    }
}
