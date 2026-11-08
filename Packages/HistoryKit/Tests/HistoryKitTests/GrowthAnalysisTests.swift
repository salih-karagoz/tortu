import Foundation
import Testing
@testable import HistoryKit
import ScanCore

@Suite("Growth analysis")
struct GrowthAnalysisTests {
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    static func series(_ dailyBytes: [Int64], id: String = "test") -> Series {
        Series(id: id, samples: dailyBytes.enumerated().map { index, bytes in
            Sample(
                timestamp: start.addingTimeInterval(Double(index) * 86_400),
                bytes: ByteCount(bytes)
            )
        })
    }

    @Test("A steady climb reports its slope per day")
    func steadyGrowth() throws {
        let rate = try #require(GrowthAnalysis.rate(of: Self.series([0, 1_000, 2_000, 3_000])))
        #expect(abs(rate.bytesPerDay - 1_000) < 0.001)
        #expect(rate.sampleCount == 4)
        #expect(rate.isGrowing)
    }

    @Test("A flat series does not report growth")
    func flatSeries() throws {
        let rate = try #require(GrowthAnalysis.rate(of: Self.series([500, 500, 500, 500])))
        #expect(abs(rate.bytesPerDay) < 0.001)
        #expect(!rate.isGrowing)
    }

    @Test("A shrinking series reports a negative slope")
    func shrinking() throws {
        let rate = try #require(GrowthAnalysis.rate(of: Self.series([3_000, 2_000, 1_000])))
        #expect(rate.bytesPerDay < 0)
        #expect(rate.formattedPerDay.hasPrefix("−"))
    }

    /// The reason the slope is least squares and not first-to-last: a cleanup
    /// in the middle of the window would otherwise make a category that is
    /// filling the disk look like one that is emptying it.
    @Test("A cleanup mid-window does not hide the underlying growth")
    func cleanupDoesNotMaskGrowth() throws {
        // Climbs for four days, is wiped, climbs again. First-to-last reads as
        // a small drop; the trend is clearly upward.
        let samples = Self.series([1_000, 2_000, 3_000, 4_000, 0, 1_000, 2_000, 3_000])
        let rate = try #require(GrowthAnalysis.rate(of: samples))
        let firstToLast = Double(3_000 - 1_000) / 7
        #expect(rate.bytesPerDay > 0, "the trend should read as growth")
        #expect(rate.bytesPerDay != firstToLast)
    }

    @Test("Too few samples report nothing rather than a guess")
    func needsEnoughSamples() {
        #expect(GrowthAnalysis.rate(of: Self.series([100, 200])) == nil)
        #expect(GrowthAnalysis.rate(of: Series(id: "empty", samples: [])) == nil)
    }

    @Test("Samples taken at the same instant report nothing")
    func zeroSpan() {
        let series = Series(id: "same", samples: (0 ..< 4).map { _ in
            Sample(timestamp: Self.start, bytes: ByteCount(100))
        })
        #expect(GrowthAnalysis.rate(of: series) == nil)
    }

    @Test("Free space falling at a known rate projects a date")
    func projectsExhaustion() throws {
        // Free space dropping by 10 GB a day, with 30 GB left: three days.
        let free = Series(id: "free", samples: [
            Sample(timestamp: Self.start, bytes: ByteCount(50_000_000_000)),
            Sample(timestamp: Self.start.addingTimeInterval(86_400), bytes: ByteCount(40_000_000_000)),
            Sample(timestamp: Self.start.addingTimeInterval(2 * 86_400), bytes: ByteCount(30_000_000_000)),
        ])
        let rate = try #require(GrowthAnalysis.rate(of: free))
        let date = try #require(GrowthAnalysis.projectedExhaustion(
            free: ByteCount(30_000_000_000), rate: rate, from: Self.start
        ))
        let days = date.timeIntervalSince(Self.start) / 86_400
        #expect(abs(days - 3) < 0.01)
    }

    @Test("Rising free space projects no exhaustion date")
    func noProjectionWhenRising() throws {
        let rate = try #require(GrowthAnalysis.rate(of: Self.series([10, 20, 30])))
        #expect(GrowthAnalysis.projectedExhaustion(
            free: ByteCount(1_000), rate: rate, from: Self.start
        ) == nil)
    }

    @Test("A projection further out than ten years is not offered")
    func noAbsurdProjections() throws {
        let barelyFalling = Series(id: "slow", samples: [
            Sample(timestamp: Self.start, bytes: ByteCount(1_000)),
            Sample(timestamp: Self.start.addingTimeInterval(86_400), bytes: ByteCount(999)),
            Sample(timestamp: Self.start.addingTimeInterval(2 * 86_400), bytes: ByteCount(998)),
        ])
        let rate = try #require(GrowthAnalysis.rate(of: barelyFalling))
        #expect(GrowthAnalysis.projectedExhaustion(
            free: ByteCount(50_000_000_000), rate: rate, from: Self.start
        ) == nil)
    }

    @Test("Ranking puts the fastest-growing category first")
    func ranksByGrowth() {
        let ranked = GrowthAnalysis.rankedByGrowth([
            Self.series([0, 100, 200], id: "slow"),
            Self.series([0, 5_000, 10_000], id: "fast"),
            Self.series([1_000, 500, 0], id: "shrinking"),
        ])
        #expect(ranked.map(\.series.id) == ["fast", "slow"])
        #expect(!ranked.contains { $0.series.id == "shrinking" })
    }

    @Test("A series can be clipped to a recent window")
    func clipsToWindow() {
        let now = Self.start.addingTimeInterval(10 * 86_400)
        let clipped = Self.series([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
            .clipped(to: 3 * 86_400, now: now)
        #expect(clipped.samples.count == 4)
    }

    @Test("Samples are kept in time order however they arrive")
    func sortsSamples() {
        let series = Series(id: "x", samples: [
            Sample(timestamp: Self.start.addingTimeInterval(86_400), bytes: ByteCount(2)),
            Sample(timestamp: Self.start, bytes: ByteCount(1)),
        ])
        #expect(series.earliest?.bytes == ByteCount(1))
        #expect(series.latest?.bytes == ByteCount(2))
    }
}
