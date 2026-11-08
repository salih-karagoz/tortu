import Foundation
import RulesEngine
import ScanCore

/// What the user is shown and asked to confirm.
public struct CleanupPlan: Sendable {
    public let evaluations: [RuleEvaluation]

    public init(evaluations: [RuleEvaluation]) {
        self.evaluations = evaluations
    }

    /// Rules with something to remove and nothing in the way.
    public var actionable: [RuleEvaluation] {
        evaluations.filter(\.isActionable)
    }

    /// Rules that found something but cannot run because an application that
    /// owns the files is open.
    public var blocked: [RuleEvaluation] {
        evaluations.filter { !$0.candidates.isEmpty && !$0.blockingApplications.isEmpty }
    }

    public var estimatedReclaim: ByteCount {
        actionable.reduce(ByteCount.zero) { $0 + $1.reclaimable }
    }

    public var requiresHelper: Bool {
        actionable.contains { $0.rule.requiresRoot }
    }

    public func evaluation(id: String) -> RuleEvaluation? {
        evaluations.first { $0.id == id }
    }
}

/// What actually happened, measured rather than predicted.
///
/// `reclaimed` is the difference between volume readings taken before and
/// after, not the sum of what was removed. The two disagree often enough that
/// reporting the estimate as the result would be dishonest: measuring 30 GB of
/// files once returned 8 GB because most of them lived behind a mount, and
/// another run that removed 3.3 GB returned 13.6 GB because the system
/// released purgeable space at the same moment.
public struct CleanupResult: Sendable {
    public let removedPaths: [String]
    public let estimated: ByteCount
    public let reclaimed: ByteCount
    public let skipped: [SkippedPath]
    public let wasDryRun: Bool

    public init(
        removedPaths: [String],
        estimated: ByteCount,
        reclaimed: ByteCount,
        skipped: [SkippedPath] = [],
        wasDryRun: Bool = false
    ) {
        self.removedPaths = removedPaths
        self.estimated = estimated
        self.reclaimed = reclaimed
        self.skipped = skipped
        self.wasDryRun = wasDryRun
    }

    public var removedPathCount: Int { removedPaths.count }

    /// True when the volume returned materially less than the scan predicted.
    /// The interface shows this rather than hiding it.
    public var underDelivered: Bool {
        guard !wasDryRun, estimated > .zero else { return false }
        return reclaimed.rawValue < Int64(Double(estimated.rawValue) * 0.8)
    }

    public struct SkippedPath: Sendable, Hashable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }
}
