import Foundation
import Testing
@testable import RulesEngine
import SafetyKit
import ScanCore

@Suite("Rule evaluation")
struct RuleEvaluatorTests {
    static func candidate(_ name: String, daysAgo: Double, size: Int64 = 1_000) -> CandidatePath {
        CandidatePath(
            path: "/tmp/\(name)",
            size: ByteCount(size),
            modified: Date(timeIntervalSince1970: 1_000_000_000 - daysAgo * 86_400),
            isDirectory: true
        )
    }

    static func build(_ project: String, _ name: String, daysAgo: Double) -> CandidatePath {
        CandidatePath(
            path: "/Users/someone/\(project)/.dart_tool/flutter_build/\(name)",
            size: ByteCount(1_000),
            modified: Date(timeIntervalSince1970: 1_000_000_000 - daysAgo * 86_400),
            isDirectory: true
        )
    }

    /// `~/**/.dart_tool/flutter_build/*` matches in every Flutter project on
    /// the machine. Sorting one flat list keeps the two newest anywhere, so a
    /// project not touched this week loses every warm build it had — which is
    /// the opposite of what the strategy promises.
    @Test("keepNewest counts per directory, not across every project at once")
    func keepNewestPerDirectory() {
        let evaluator = RuleEvaluator(clock: { Date(timeIntervalSince1970: 1_000_000_000) })
        let matches = [
            Self.build("alpha", "a1", daysAgo: 1),
            Self.build("alpha", "a2", daysAgo: 2),
            Self.build("alpha", "a3", daysAgo: 3),
            Self.build("beta", "b1", daysAgo: 40),
            Self.build("beta", "b2", daysAgo: 41),
            Self.build("beta", "b3", daysAgo: 42),
        ]

        let (candidates, kept) = evaluator.apply(.keepNewest(2), to: matches)

        #expect(kept.count == 4)
        #expect(Set(candidates.map { ($0.path as NSString).lastPathComponent }) == ["a3", "b3"])
        // Beta's newest is older than everything alpha has, and survives anyway.
        #expect(kept.contains { $0.path.hasSuffix("/b1") })
    }

    @Test("keepNewest keeps the most recent and proposes the rest")
    func keepNewest() {
        let evaluator = RuleEvaluator(
            clock: { Date(timeIntervalSince1970: 1_000_000_000) }
        )
        let matches = [
            Self.candidate("oldest", daysAgo: 30),
            Self.candidate("newest", daysAgo: 1),
            Self.candidate("middle", daysAgo: 10),
        ]
        let (candidates, kept) = evaluator.apply(.keepNewest(2), to: matches)

        #expect(kept.map { $0.path.hasSuffix("newest") || $0.path.hasSuffix("middle") }
            .allSatisfy { $0 })
        #expect(kept.count == 2)
        #expect(candidates.count == 1)
        #expect(candidates[0].path.hasSuffix("oldest"))
    }

    @Test("keepNewest with fewer matches than it keeps proposes nothing")
    func keepNewestBelowThreshold() {
        let evaluator = RuleEvaluator()
        let (candidates, kept) = evaluator.apply(
            .keepNewest(2), to: [Self.candidate("only", daysAgo: 5)]
        )
        #expect(candidates.isEmpty)
        #expect(kept.count == 1)
    }

    @Test("olderThan uses the injected clock")
    func olderThan() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let evaluator = RuleEvaluator(clock: { now })
        let (candidates, kept) = evaluator.apply(.olderThan(days: 7), to: [
            Self.candidate("stale", daysAgo: 30),
            Self.candidate("fresh", daysAgo: 2),
        ])
        #expect(candidates.count == 1)
        #expect(candidates[0].path.hasSuffix("stale"))
        #expect(kept.count == 1)
    }

    @Test("deleteAll proposes everything it matched")
    func deleteAll() {
        let evaluator = RuleEvaluator()
        let matches = [Self.candidate("a", daysAgo: 1), Self.candidate("b", daysAgo: 2)]
        let (candidates, kept) = evaluator.apply(.deleteAll, to: matches)
        #expect(candidates.count == 2)
        #expect(kept.isEmpty)
    }

    @Test("A rule measures real directories and reports its blockers")
    func evaluatesRealPaths() async throws {
        let home = URL.temporaryDirectory.appending(path: "tortu-eval-\(UUID().uuidString)")
        let cache = home.appending(path: "Library/Caches/example")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 40_000)
            .write(to: cache.appending(path: "blob.bin"))
        defer { try? FileManager.default.removeItem(at: home) }

        let rule = CleanupRule(
            id: "test.cache", name: LocalizedText(en: "Test"), category: .developer,
            paths: ["~/Library/Caches/*"], strategy: .deleteAll,
            blockedByProcesses: ["com.example.running"],
            cost: LocalizedText(en: "nothing")
        )
        let evaluator = RuleEvaluator(
            matcher: PathMatcher(home: home.path(percentEncoded: false)),
            guardian: ProcessGuard(applications: StubApplications(["com.example.running"]))
        )

        let evaluation = await evaluator.evaluate(rule)
        #expect(evaluation.candidates.count == 1)
        #expect(evaluation.reclaimable >= ByteCount(40_000))
        #expect(evaluation.blockingApplications == ["com.example.running"])
        // Blocked means not actionable, however much it would reclaim.
        #expect(!evaluation.isActionable)
    }
}
