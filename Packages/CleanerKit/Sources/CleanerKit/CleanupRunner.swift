import Foundation
import RulesEngine
import SafetyKit
import ScanCore

/// Carries out a plan, or shows exactly what carrying it out would do.
public struct CleanupRunner: Sendable {
    public enum Mode: Sendable {
        case dryRun
        case execute
    }

    public struct Options: Sendable {
        /// Caches go straight out. Moving gigabytes of them to the Trash
        /// frees no space at all until the user empties it, which looks like
        /// the cleanup did nothing.
        public var moveToTrash: Bool
        public var home: String

        public init(moveToTrash: Bool = false, home: String = NSHomeDirectory()) {
            self.moveToTrash = moveToTrash
            self.home = home
        }

        public static let `default` = Options()
    }

    private let options: Options
    private let remover: any FileRemoving
    /// Absent until the helper is installed and allowed. Root rules are then
    /// reported as skipped rather than attempted, which is how the interface
    /// can say why nothing happened.
    private let helper: HelperClient?

    public init(
        options: Options = .default,
        remover: any FileRemoving = SystemFileRemover(),
        helper: HelperClient? = nil
    ) {
        self.options = options
        self.remover = remover
        self.helper = helper
    }

    public func run(
        _ plan: CleanupPlan,
        ruleIDs: Set<String>? = nil,
        mode: Mode = .dryRun,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> CleanupResult {
        let selected = plan.actionable.filter { ruleIDs?.contains($0.id) ?? true }
        let before = try? VolumeStats.forPath(options.home)

        var removed: [String] = []
        var skipped: [CleanupResult.SkippedPath] = []
        var estimated = ByteCount.zero

        for evaluation in selected {
            // Root rules are the helper's business. The helper is asked for a
            // rule identifier and resolves the paths itself from its own
            // signed copy of the rules; nothing from here reaches it as a
            // path. When there is no helper, the rule is reported as skipped
            // rather than quietly dropped.
            if evaluation.rule.requiresRoot {
                guard let helper else {
                    for candidate in evaluation.candidates {
                        skipped.append(
                            .init(path: candidate.path, reason: "requires the privileged helper")
                        )
                    }
                    continue
                }
                do {
                    let report = try await helper.perform(
                        ruleIdentifier: evaluation.rule.id, dryRun: mode == .dryRun
                    )
                    estimated += ByteCount(report.reclaimedBytes)
                    // The helper reports counts, not paths; the rule stands in
                    // for them so the total stays honest.
                    for _ in 0 ..< report.removedPathCount {
                        removed.append(evaluation.rule.id)
                    }
                } catch {
                    for candidate in evaluation.candidates {
                        skipped.append(
                            .init(path: candidate.path, reason: String(describing: error))
                        )
                    }
                }
                continue
            }

            for candidate in evaluation.candidates {
                do {
                    try PathSafety.validateForRemoval(candidate.path, home: options.home)
                } catch {
                    skipped.append(.init(path: candidate.path, reason: String(describing: error)))
                    continue
                }

                estimated += candidate.size
                onProgress?(candidate.path)

                guard mode == .execute else {
                    removed.append(candidate.path)
                    continue
                }

                do {
                    if options.moveToTrash {
                        try remover.trash(at: candidate.path)
                    } else {
                        try remover.remove(at: candidate.path)
                    }
                    removed.append(candidate.path)
                } catch {
                    skipped.append(.init(path: candidate.path, reason: error.localizedDescription))
                }
            }
        }

        var reclaimed = ByteCount.zero
        if mode == .execute, let before, let after = try? VolumeStats.forPath(options.home) {
            reclaimed = ByteCount(after.available.rawValue - before.available.rawValue)
            if reclaimed < .zero { reclaimed = .zero }
        }

        return CleanupResult(
            removedPaths: removed,
            estimated: estimated,
            reclaimed: mode == .execute ? reclaimed : estimated,
            skipped: skipped,
            wasDryRun: mode == .dryRun
        )
    }
}
