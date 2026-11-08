import Foundation
import HistoryKit
import RulesEngine
import ScanCore

/// Everything the Panel's charts draw, shaped once per render.
///
/// The charts take this rather than the stored rows, so that each of them is
/// only a drawing and the arithmetic — slopes, projections, which category is
/// the featured one — happens in one place that can be read on its own.
struct PanelData {
    var now: Date
    var capacity: ByteCount
    var free: ByteCount
    /// Used space over time, which is what the waterline rises along.
    var used: [Sample]
    /// Free space falling, which is the slope the projection is taken from.
    var freeRate: GrowthRate?
    var exhaustion: Date?
    var categories: [CategoryTrack]
    var cleanups: [CleanupPoint]

    var usedFraction: Double {
        guard capacity.rawValue > 0 else { return 0 }
        return Double(capacity.rawValue - free.rawValue) / Double(capacity.rawValue)
    }

    var hasVolumeHistory: Bool { used.count >= GrowthAnalysis.minimumSamples }
    var hasCategoryHistory: Bool { categories.contains { $0.series.samples.count >= 2 } }

    /// Days from now until the volume is full, when that can be said at all.
    var daysToExhaustion: Int? {
        guard let exhaustion else { return nil }
        let days = exhaustion.timeIntervalSince(now) / 86_400
        guard days.isFinite, days >= 0 else { return nil }
        return Int(days.rounded())
    }

    /// The projected rise, as points the chart can draw as a dashed line.
    ///
    /// It starts at the last real reading rather than at the capacity line,
    /// so the dashes continue the solid line instead of floating above it.
    var projection: [Sample] {
        guard let last = used.last, let rate = freeRate, rate.bytesPerDay < 0,
              let exhaustion else { return [] }
        let span = exhaustion.timeIntervalSince(last.timestamp)
        guard span > 0 else { return [] }
        let steps = 18
        return (0...steps).map { step in
            let fraction = Double(step) / Double(steps)
            let bytes = Double(last.bytes.rawValue) + -rate.bytesPerDay * (span * fraction) / 86_400
            return Sample(
                timestamp: last.timestamp.addingTimeInterval(span * fraction),
                bytes: ByteCount(Int64(min(bytes, Double(capacity.rawValue))))
            )
        }
    }

    /// The categories that grew fastest over the last fortnight, which is the
    /// order the growth row and the return chart both use.
    var ranked: [CategoryTrack] {
        categories
            .filter { ($0.rate14 ?? 0) > 0 }
            .sorted { ($0.rate14 ?? 0) > ($1.rate14 ?? 0) }
    }

    /// The categories holding the most right now.
    var largest: [CategoryTrack] {
        categories
            .filter { $0.latest.rawValue > 0 }
            .sorted { $0.latest > $1.latest }
    }

    static let empty = PanelData(
        now: .now, capacity: .zero, free: .zero, used: [],
        freeRate: nil, exhaustion: nil, categories: [], cleanups: []
    )
}

struct CategoryTrack: Identifiable, Sendable {
    let id: String
    let name: String
    let series: Series
    let latest: ByteCount
    /// Bytes per day over the last fortnight and the last week. Two windows,
    /// because the difference between them is the only thing that says
    /// whether a category is speeding up.
    let rate14: Double?
    let rate7: Double?
}

struct CleanupPoint: Identifiable, Sendable {
    let id: Date
    let date: Date
    let estimated: ByteCount
    let reclaimed: ByteCount
    let ruleCount: Int
    let wasDryRun: Bool

    /// How far the volume fell short of the estimate, as a fraction. Negative
    /// means less came back than was promised.
    var deviation: Double? {
        guard estimated.rawValue > 0 else { return nil }
        return Double(reclaimed.rawValue - estimated.rawValue) / Double(estimated.rawValue)
    }
}

extension PanelData {
    /// How fast a category is filling, measured from the last time it was
    /// cleared.
    ///
    /// A least-squares slope across a window that contains a cleanup
    /// regresses towards zero: the cliff cancels the climb, and a category
    /// that refills within a week reads as one that is not growing at all.
    /// That is the opposite of what the product claims to know. So the window
    /// is cut at the last drop first, and only falls back to the whole window
    /// when too few readings are left after it to fit a line to.
    static func growth(of series: Series, window: TimeInterval, now: Date) -> Double? {
        let clipped = series.clipped(to: window, now: now)
        let recent = sinceLastDrop(clipped)
        let chosen = recent.samples.count >= GrowthAnalysis.minimumSamples ? recent : clipped
        return GrowthAnalysis.rate(of: chosen)?.bytesPerDay
    }

    /// The tail of a series since the last time it fell sharply.
    ///
    /// A third is the threshold: caches wobble as files are added and
    /// evicted, but a cleanup removes most of one at once, and nothing else
    /// does.
    static func sinceLastDrop(_ series: Series) -> Series {
        let samples = series.samples
        guard samples.count >= 2 else { return series }
        var start = 0
        for index in 1..<samples.count {
            let previous = Double(samples[index - 1].bytes.rawValue)
            let current = Double(samples[index].bytes.rawValue)
            if previous > 0, current < previous * 0.67 { start = index }
        }
        return Series(id: series.id, samples: Array(samples[start...]))
    }

    /// Builds the panel's view of the stored measurements.
    ///
    /// `names` maps a rule identifier to the name the user sees. A sample for
    /// a rule that is no longer in the catalogue keeps its identifier, so a
    /// removed rule does not silently drop out of the history.
    static func build(
        volumeSamples: [VolumeSample],
        categorySamples: [CategorySample],
        cleanupRecords: [CleanupRecord],
        names: [String: String],
        stats: VolumeStats?,
        now: Date = .now
    ) -> PanelData {
        let capacity = ByteCount(stats?.total.rawValue ?? volumeSamples.last?.totalBytes ?? 0)
        let free = ByteCount(stats?.available.rawValue ?? volumeSamples.last?.availableBytes ?? 0)

        let used = volumeSamples.map {
            Sample(timestamp: $0.timestamp, bytes: ByteCount($0.usedBytes))
        }
        let freeSeries = Series(id: "free", samples: volumeSamples.map {
            Sample(timestamp: $0.timestamp, bytes: ByteCount($0.availableBytes))
        })
        // Seven days, because that is the window the summary box names. A
        // longer one would hide a change of habit; a shorter one would make
        // the projection jump around after every cleanup.
        let recentFree = freeSeries.clipped(to: 7 * 86_400, now: now)
        let rate = GrowthAnalysis.rate(of: recentFree.samples.count >= GrowthAnalysis.minimumSamples
            ? recentFree : freeSeries)
        let exhaustion = rate.flatMap {
            GrowthAnalysis.projectedExhaustion(free: free, rate: $0, from: now)
        }

        let grouped = Dictionary(grouping: categorySamples, by: \.ruleID)
        let categories = grouped.map { ruleID, rows -> CategoryTrack in
            let series = Series(id: ruleID, samples: rows.map {
                Sample(timestamp: $0.timestamp, bytes: ByteCount($0.bytes))
            })
            return CategoryTrack(
                id: ruleID,
                name: names[ruleID] ?? ruleID,
                series: series,
                latest: series.latest?.bytes ?? .zero,
                rate14: growth(of: series, window: 14 * 86_400, now: now),
                rate7: growth(of: series, window: 7 * 86_400, now: now)
            )
        }

        let cleanups = cleanupRecords
            .filter { !$0.wasDryRun }
            .map {
                CleanupPoint(
                    id: $0.timestamp,
                    date: $0.timestamp,
                    estimated: ByteCount($0.estimatedBytes),
                    reclaimed: ByteCount($0.reclaimedBytes),
                    ruleCount: $0.ruleIDs.isEmpty
                        ? 0 : $0.ruleIDs.split(separator: ",").count,
                    wasDryRun: $0.wasDryRun
                )
            }
            .sorted { $0.date < $1.date }

        return PanelData(
            now: now,
            capacity: capacity,
            free: free,
            used: used,
            freeRate: rate,
            exhaustion: exhaustion,
            categories: categories,
            cleanups: cleanups
        )
    }
}
