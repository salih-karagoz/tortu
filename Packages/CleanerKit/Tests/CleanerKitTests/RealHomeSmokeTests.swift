import Foundation
import Testing
@testable import CleanerKit
import RulesEngine
import ScanCore

/// Read-only, and structurally so.
///
/// This suite runs against the developer's real home directory, which makes it
/// the one place in the test suite where a mistake would cost someone their
/// files. Three things stand in the way, and all three have to be removed
/// deliberately for anything to be deleted:
///
/// 1. The runner is always built with `RecordingFileRemover`, which appends to
///    an array and never calls `FileManager`.
/// 2. The run is always `.dryRun`.
/// 3. Free space is measured before and after, and the test fails if it moved.
///
/// Never swap in `SystemFileRemover` here, and never pass `.execute`.
@Suite("Real home", .enabled(if: ProcessInfo.processInfo.environment["TORTU_SMOKE"] != nil))
struct RealHomeSmokeTests {
    @Test("Evaluate the bundled rules against this machine")
    func evaluateBundledRules() async throws {
        let freeBefore = try VolumeStats.forHomeVolume().available
        let store = try RuleStore.bundled()
        let evaluator = RuleEvaluator()
        let started = ContinuousClock.now
        let evaluations = await evaluator.evaluate(store.rules)
        let elapsed = ContinuousClock.now - started
        print("SMOKE toplam değerlendirme: \(elapsed.components.seconds) s")

        let plan = CleanupPlan(evaluations: evaluations)

        for evaluation in plan.evaluations.sorted(by: { $0.reclaimable > $1.reclaimable }) {
            let blockers = evaluation.blockingApplications.joined(separator: ",")
            print("SMOKE \(evaluation.reclaimable.formatted.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + " | \(evaluation.candidates.count) yol"
                + " | \(evaluation.rule.id)"
                + (blockers.isEmpty ? "" : " | ENGEL: \(blockers)")
                + (evaluation.kept.isEmpty ? "" : " | korunan: \(evaluation.kept.count)"))
        }
        print("SMOKE TOPLAM eylenebilir: \(plan.estimatedReclaim.formatted)")

        // A dry run must leave the disk exactly as it found it.
        let remover = RecordingFileRemover()
        let result = await CleanupRunner(remover: remover).run(plan, mode: .dryRun)
        #expect(remover.removed.isEmpty)
        #expect(remover.trashed.isEmpty)
        #expect(result.wasDryRun)
        print("SMOKE kuru çalıştırma: \(result.removedPathCount) yol dokunulmadan listelendi")

        // Proof rather than promise: if this suite had deleted anything, the
        // volume would say so. A 50 MB window absorbs the ordinary churn of a
        // machine that is also doing other things.
        let freeAfter = try VolumeStats.forHomeVolume().available
        let drift = abs(freeAfter.rawValue - freeBefore.rawValue)
        #expect(drift < 50_000_000, "free space moved by \(drift) bytes during a read-only suite")
        print("SMOKE disk değişimi: \(drift) bayt (silme yok)")
    }
}
