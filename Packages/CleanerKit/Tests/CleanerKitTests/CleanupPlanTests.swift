import Foundation
import Testing
@testable import CleanerKit
import RulesEngine
import ScanCore

@Suite("Cleanup plans")
struct CleanupPlanTests {
    static func rule(
        id: String, root: Bool = false, blocked: [String] = []
    ) -> CleanupRule {
        CleanupRule(
            id: id, name: LocalizedText(en: id), category: .developer,
            paths: ["~/Library/Caches/\(id)"], strategy: .deleteAll,
            blockedByProcesses: blocked, requiresRoot: root,
            cost: LocalizedText(en: "nothing")
        )
    }

    static func candidate(_ path: String, bytes: Int64) -> CandidatePath {
        CandidatePath(path: path, size: ByteCount(bytes), modified: .now, isDirectory: true)
    }

    static func evaluation(
        id: String, bytes: Int64, root: Bool = false, blockers: [String] = []
    ) -> RuleEvaluation {
        RuleEvaluation(
            rule: rule(id: id, root: root, blocked: blockers),
            candidates: bytes > 0 ? [candidate("/Users/x/Library/Caches/\(id)", bytes: bytes)] : [],
            kept: [],
            blockingApplications: blockers
        )
    }

    @Test("A plan totals only what it can act on")
    func totalsActionableOnly() {
        let plan = CleanupPlan(evaluations: [
            Self.evaluation(id: "a", bytes: 100),
            Self.evaluation(id: "b", bytes: 50, blockers: ["com.apple.dt.Xcode"]),
            Self.evaluation(id: "c", bytes: 0),
        ])
        #expect(plan.actionable.count == 1)
        #expect(plan.estimatedReclaim == ByteCount(100))
        #expect(plan.blocked.count == 1)
        #expect(!plan.requiresHelper)
    }

    @Test("A plan knows when it needs the privileged helper")
    func detectsHelperNeed() {
        let plan = CleanupPlan(evaluations: [Self.evaluation(id: "sim", bytes: 10, root: true)])
        #expect(plan.requiresHelper)
    }

    @Test("A result that returned far less than estimated is flagged")
    func underDelivery() {
        let misleading = CleanupResult(
            removedPaths: ["/a"], estimated: ByteCount(30), reclaimed: ByteCount(8)
        )
        let honest = CleanupResult(
            removedPaths: ["/a"], estimated: ByteCount(30), reclaimed: ByteCount(29)
        )
        #expect(misleading.underDelivered)
        #expect(!honest.underDelivered)
    }

    @Test("A dry run is never flagged as under-delivering")
    func dryRunIsNotFlagged() {
        let dry = CleanupResult(
            removedPaths: ["/a"], estimated: ByteCount(30),
            reclaimed: ByteCount(30), wasDryRun: true
        )
        #expect(!dry.underDelivered)
    }
}

@Suite("Cleanup runner")
struct CleanupRunnerTests {
    /// Builds a real home with real files, so path safety runs against
    /// something that exists.
    static func makeHome() throws -> URL {
        let home = URL.temporaryDirectory.appending(path: "tortu-run-\(UUID().uuidString)")
        for name in ["alpha", "beta"] {
            let directory = home.appending(path: "Library/Caches/\(name)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: 20_000)
                .write(to: directory.appending(path: "blob.bin"))
        }
        return home
    }

    static func evaluation(for paths: [String], id: String = "test.rule") -> RuleEvaluation {
        RuleEvaluation(
            rule: CleanupRule(
                id: id, name: LocalizedText(en: id), category: .developer,
                paths: ["~/Library/Caches/*"], strategy: .deleteAll,
                cost: LocalizedText(en: "nothing")
            ),
            candidates: paths.map {
                CandidatePath(path: $0, size: ByteCount(20_000), modified: .now, isDirectory: true)
            },
            kept: [],
            blockingApplications: []
        )
    }

    @Test("A dry run removes nothing")
    func dryRunRemovesNothing() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ["alpha", "beta"].map {
            home.appending(path: "Library/Caches/\($0)").path(percentEncoded: false)
        }

        let remover = RecordingFileRemover()
        let runner = CleanupRunner(
            options: .init(home: home.path(percentEncoded: false)), remover: remover
        )
        let result = await runner.run(
            CleanupPlan(evaluations: [Self.evaluation(for: paths)]), mode: .dryRun
        )

        #expect(result.wasDryRun)
        #expect(result.removedPathCount == 2)
        #expect(remover.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: paths[0]))
    }

    @Test("Executing removes exactly the selected paths")
    func executeRemovesPaths() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ["alpha", "beta"].map {
            home.appending(path: "Library/Caches/\($0)").path(percentEncoded: false)
        }

        let remover = RecordingFileRemover()
        let runner = CleanupRunner(
            options: .init(home: home.path(percentEncoded: false)), remover: remover
        )
        let result = await runner.run(
            CleanupPlan(evaluations: [Self.evaluation(for: paths)]), mode: .execute
        )

        #expect(remover.removed.sorted() == paths.sorted())
        #expect(result.removedPathCount == 2)
        #expect(!result.wasDryRun)
    }

    @Test("An unsafe path is skipped with a reason, not removed")
    func skipsUnsafePaths() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let remover = RecordingFileRemover()
        let runner = CleanupRunner(
            options: .init(home: home.path(percentEncoded: false)), remover: remover
        )
        let result = await runner.run(
            CleanupPlan(evaluations: [Self.evaluation(for: ["/System/Library/Caches/x"])]),
            mode: .execute
        )

        #expect(remover.removed.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.skipped[0].path == "/System/Library/Caches/x")
    }

    @Test("A root rule is skipped until the helper exists")
    func skipsRootRules() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let rootRule = RuleEvaluation(
            rule: CleanupRule(
                id: "sim", name: LocalizedText(en: "sim"), category: .developer,
                paths: ["/Library/Developer/CoreSimulator/Caches/dyld/*"],
                strategy: .deleteAll, requiresRoot: true, cost: LocalizedText(en: "x")
            ),
            candidates: [CandidatePath(
                path: "/Library/Developer/CoreSimulator/Caches/dyld/abc",
                size: ByteCount(1_000), modified: .now, isDirectory: true
            )],
            kept: [], blockingApplications: []
        )

        let remover = RecordingFileRemover()
        let result = await CleanupRunner(
            options: .init(home: home.path(percentEncoded: false)), remover: remover
        ).run(CleanupPlan(evaluations: [rootRule]), mode: .execute)

        #expect(remover.removed.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.skipped[0].reason.contains("helper"))
    }

    @Test("A failed removal is recorded, and the rest still run")
    func continuesAfterFailure() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ["alpha", "beta"].map {
            home.appending(path: "Library/Caches/\($0)").path(percentEncoded: false)
        }

        let remover = RecordingFileRemover(failingPaths: [paths[0]])
        let result = await CleanupRunner(
            options: .init(home: home.path(percentEncoded: false)), remover: remover
        ).run(CleanupPlan(evaluations: [Self.evaluation(for: paths)]), mode: .execute)

        #expect(remover.removed == [paths[1]])
        #expect(result.removedPathCount == 1)
        #expect(result.skipped.count == 1)
    }

    @Test("Selecting a subset runs only those rules")
    func runsSelectedRulesOnly() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let alpha = home.appending(path: "Library/Caches/alpha").path(percentEncoded: false)
        let beta = home.appending(path: "Library/Caches/beta").path(percentEncoded: false)

        let remover = RecordingFileRemover()
        let plan = CleanupPlan(evaluations: [
            Self.evaluation(for: [alpha], id: "rule.alpha"),
            Self.evaluation(for: [beta], id: "rule.beta"),
        ])
        _ = await CleanupRunner(
            options: .init(home: home.path(percentEncoded: false)), remover: remover
        ).run(plan, ruleIDs: ["rule.alpha"], mode: .execute)

        #expect(remover.removed == [alpha])
    }

    @Test("Trash mode trashes instead of deleting")
    func trashMode() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let alpha = home.appending(path: "Library/Caches/alpha").path(percentEncoded: false)

        let remover = RecordingFileRemover()
        _ = await CleanupRunner(
            options: .init(moveToTrash: true, home: home.path(percentEncoded: false)),
            remover: remover
        ).run(CleanupPlan(evaluations: [Self.evaluation(for: [alpha])]), mode: .execute)

        #expect(remover.trashed == [alpha])
        #expect(remover.removed.isEmpty)
    }
}
