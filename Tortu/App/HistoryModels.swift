import Foundation
import HistoryKit
import ScanCore
import SwiftData

/// One volume reading, stored so that growth can be shown over time.
///
/// The point of keeping these is the number no snapshot tool can produce: how
/// fast a category refills. A single reading says the disk is full; a series
/// says which tool filled it and how soon it will happen again.
@Model
final class VolumeSample {
    var timestamp: Date
    var volumeIdentifier: String
    var totalBytes: Int64
    var availableBytes: Int64

    init(
        timestamp: Date = .now,
        volumeIdentifier: String,
        totalBytes: Int64,
        availableBytes: Int64
    ) {
        self.timestamp = timestamp
        self.volumeIdentifier = volumeIdentifier
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    var usedBytes: Int64 { totalBytes - availableBytes }
}

/// What one rule was holding the last time it was measured.
@Model
final class CategorySample {
    var timestamp: Date
    var ruleID: String
    var bytes: Int64

    init(timestamp: Date = .now, ruleID: String, bytes: Int64) {
        self.timestamp = timestamp
        self.ruleID = ruleID
        self.bytes = bytes
    }
}

/// One rule as it stood when a cleanup ran.
///
/// Only the estimate is per rule. What the volume gave back is a single
/// figure for the whole run — free space is measured once before and once
/// after — so attributing part of it to one rule would be a guess. The
/// History screen therefore shows per-rule estimates against one shared
/// outcome, rather than inventing a split.
struct RecordedRule: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let estimatedBytes: Int64
    let pathCount: Int
}

/// A cleanup that was run, with the estimate beside what the volume returned.
@Model
final class CleanupRecord {
    var timestamp: Date
    var ruleIDs: String
    var pathCount: Int
    var estimatedBytes: Int64
    var reclaimedBytes: Int64
    var skippedCount: Int
    var wasDryRun: Bool
    /// `RecordedRule` values as JSON. A stored blob rather than a relationship
    /// because these are a frozen record of one moment: the rule may since
    /// have been renamed, changed or removed from the catalogue, and the
    /// history must still read the way it did when it was written.
    ///
    /// Defaulted so that a store written by an earlier version opens without
    /// a migration step.
    var ruleSummary: String = ""

    init(
        timestamp: Date = .now,
        ruleIDs: String,
        pathCount: Int,
        estimatedBytes: Int64,
        reclaimedBytes: Int64,
        skippedCount: Int,
        wasDryRun: Bool,
        ruleSummary: String = ""
    ) {
        self.timestamp = timestamp
        self.ruleIDs = ruleIDs
        self.pathCount = pathCount
        self.estimatedBytes = estimatedBytes
        self.reclaimedBytes = reclaimedBytes
        self.skippedCount = skippedCount
        self.wasDryRun = wasDryRun
        self.ruleSummary = ruleSummary
    }

    var rules: [RecordedRule] {
        guard let data = ruleSummary.data(using: .utf8), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([RecordedRule].self, from: data)) ?? []
    }

    /// How far the outcome fell short of the estimate, as a fraction.
    var deviation: Double? {
        guard !wasDryRun, estimatedBytes > 0 else { return nil }
        return Double(reclaimedBytes - estimatedBytes) / Double(estimatedBytes)
    }

    /// True when the volume returned materially less than was estimated.
    var underDelivered: Bool {
        guard !wasDryRun, estimatedBytes > 0 else { return false }
        return reclaimedBytes < Int64(Double(estimatedBytes) * 0.8)
    }
}
