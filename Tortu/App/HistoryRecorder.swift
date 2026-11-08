import CleanerKit
import Foundation
import HistoryKit
import RulesEngine
import ScanCore
import SwiftData

/// Writes measurements into the store and reads series back out of it.
@MainActor
struct HistoryRecorder {
    let context: ModelContext

    /// Readings closer together than this are dropped. Without it, every
    /// window that opens would add a point and the chart would say more about
    /// how often the app was used than about the disk.
    static let minimumSpacing: TimeInterval = 5 * 60

    func recordVolume(_ stats: VolumeStats, now: Date = .now) {
        let identifier = stats.mountPoint
        var descriptor = FetchDescriptor<VolumeSample>(
            predicate: #Predicate { $0.volumeIdentifier == identifier },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        if let latest = try? context.fetch(descriptor).first,
           now.timeIntervalSince(latest.timestamp) < Self.minimumSpacing {
            return
        }

        context.insert(
            VolumeSample(
                timestamp: now,
                volumeIdentifier: identifier,
                totalBytes: stats.total.rawValue,
                availableBytes: stats.available.rawValue
            )
        )
        try? context.save()
    }

    func recordCategories(_ evaluations: [RuleEvaluation], now: Date = .now) {
        for evaluation in evaluations {
            context.insert(
                CategorySample(
                    timestamp: now,
                    ruleID: evaluation.rule.id,
                    bytes: evaluation.reclaimable.rawValue
                )
            )
        }
        try? context.save()
    }

    func recordCleanup(
        _ result: CleanupResult,
        plan: CleanupPlan?,
        ruleIDs: Set<String>,
        now: Date = .now
    ) {
        let rules = (plan?.evaluations ?? [])
            .filter { ruleIDs.contains($0.id) }
            .map {
                RecordedRule(
                    id: $0.id,
                    name: $0.rule.name.resolved(),
                    estimatedBytes: $0.reclaimable.rawValue,
                    pathCount: $0.candidates.count
                )
            }
            .sorted { $0.estimatedBytes > $1.estimatedBytes }
        let summary = (try? JSONEncoder().encode(rules))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""

        context.insert(
            CleanupRecord(
                timestamp: now,
                ruleIDs: ruleIDs.sorted().joined(separator: ","),
                pathCount: result.removedPathCount,
                estimatedBytes: result.estimated.rawValue,
                reclaimedBytes: result.reclaimed.rawValue,
                skippedCount: result.skipped.count,
                wasDryRun: result.wasDryRun,
                ruleSummary: summary
            )
        )
        try? context.save()
    }

    func freeSpaceSeries() -> Series {
        let descriptor = FetchDescriptor<VolumeSample>(
            sortBy: [SortDescriptor(\VolumeSample.timestamp, order: .forward)]
        )
        let samples = (try? context.fetch(descriptor)) ?? []
        return Series(id: "free", samples: samples.map {
            Sample(timestamp: $0.timestamp, bytes: ByteCount($0.availableBytes))
        })
    }

    func categorySeries() -> [Series] {
        let descriptor = FetchDescriptor<CategorySample>(
            sortBy: [SortDescriptor(\CategorySample.timestamp, order: .forward)]
        )
        let samples = (try? context.fetch(descriptor)) ?? []
        return Dictionary(grouping: samples, by: \.ruleID).map { ruleID, group in
            Series(id: ruleID, samples: group.map {
                Sample(timestamp: $0.timestamp, bytes: ByteCount($0.bytes))
            })
        }
    }

    func cleanups(limit: Int = 50) -> [CleanupRecord] {
        var descriptor = FetchDescriptor<CleanupRecord>(
            sortBy: [SortDescriptor(\CleanupRecord.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }
}
