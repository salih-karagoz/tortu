import Foundation
import SafetyKit
import ScanCore

/// One path a rule proposes to remove.
public struct CandidatePath: Sendable, Hashable, Identifiable {
    public let path: String
    public let size: ByteCount
    public let modified: Date
    public let isDirectory: Bool

    public var id: String { path }

    public init(path: String, size: ByteCount, modified: Date, isDirectory: Bool) {
        self.path = path
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
    }
}

/// What a rule would do right now, with nothing removed yet.
public struct RuleEvaluation: Sendable, Identifiable {
    public let rule: CleanupRule
    /// Paths the strategy selected for removal.
    public let candidates: [CandidatePath]
    /// Paths the strategy matched but deliberately keeps, such as the most
    /// recent build directories under `keepNewest`.
    public let kept: [CandidatePath]
    /// Applications that must be quit before this rule can run.
    public let blockingApplications: [String]

    public var id: String { rule.id }

    public var reclaimable: ByteCount {
        candidates.reduce(ByteCount.zero) { $0 + $1.size }
    }

    public var isActionable: Bool {
        !candidates.isEmpty && blockingApplications.isEmpty
    }

    public init(
        rule: CleanupRule,
        candidates: [CandidatePath],
        kept: [CandidatePath] = [],
        blockingApplications: [String] = []
    ) {
        self.rule = rule
        self.candidates = candidates
        self.kept = kept
        self.blockingApplications = blockingApplications
    }
}

/// Turns a rule into a concrete list of paths and measures them.
public struct RuleEvaluator: Sendable {
    private let matcher: PathMatcher
    private let scanner: DirectoryScanner
    private let guardian: ProcessGuard
    private let clock: @Sendable () -> Date

    public init(
        matcher: PathMatcher = PathMatcher(),
        scanner: DirectoryScanner = DirectoryScanner(),
        guardian: ProcessGuard = ProcessGuard(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.matcher = matcher
        self.scanner = scanner
        self.guardian = guardian
        self.clock = clock
    }

    public func evaluate(_ rule: CleanupRule) async -> RuleEvaluation {
        var matched: [CandidatePath] = []
        for pattern in rule.paths {
            for path in matcher.matches(pattern: pattern) {
                if let candidate = await measure(path) {
                    matched.append(candidate)
                }
            }
        }

        let (candidates, kept) = apply(rule.strategy, to: matched)
        return RuleEvaluation(
            rule: rule,
            candidates: candidates,
            kept: kept,
            blockingApplications: guardian.blockingApplications(among: rule.blockedByProcesses)
        )
    }

    /// Evaluates rules concurrently.
    ///
    /// Rules are independent, and the slow ones are slow for different reasons
    /// — one walks a project tree, another measures hundreds of directories —
    /// so running them together brings the wall clock down to roughly the
    /// slowest one rather than the sum.
    /// `onProgress` is called once per rule as it lands, in completion order
    /// rather than catalogue order, so a screen can say how many of the rules
    /// have been measured and how much they have found so far.
    public func evaluate(
        _ rules: [CleanupRule],
        onProgress: (@Sendable (RuleEvaluation) -> Void)? = nil
    ) async -> [RuleEvaluation] {
        await withTaskGroup(of: (Int, RuleEvaluation).self) { group in
            for (index, rule) in rules.enumerated() {
                group.addTask { (index, await evaluate(rule)) }
            }
            var collected: [(Int, RuleEvaluation)] = []
            for await pair in group {
                collected.append(pair)
                onProgress?(pair.1)
            }
            // Restored to the order the rules were given in, so the interface
            // does not reshuffle itself between runs.
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Splits matches into what a strategy removes and what it keeps.
    func apply(
        _ strategy: CleanupStrategy,
        to matches: [CandidatePath]
    ) -> (candidates: [CandidatePath], kept: [CandidatePath]) {
        switch strategy {
        case .deleteAll:
            return (matches, [])

        case let .keepNewest(count):
            // Newest first, so the ones left warm are the ones in use.
            let ordered = matches.sorted { $0.modified > $1.modified }
            return (Array(ordered.dropFirst(count)), Array(ordered.prefix(count)))

        case let .olderThan(days):
            let cutoff = clock().addingTimeInterval(-Double(days) * 86_400)
            let old = matches.filter { $0.modified < cutoff }
            let recent = matches.filter { $0.modified >= cutoff }
            return (old, recent)
        }
    }

    private func measure(_ path: String) async -> CandidatePath? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))

        if info.st_mode & S_IFMT == S_IFDIR {
            guard let result = try? await scanner.scan(rootPath: path) else { return nil }
            return CandidatePath(
                path: path, size: result.root.totalSize,
                modified: modified, isDirectory: true
            )
        }
        return CandidatePath(
            path: path,
            size: ByteCount(blocks: Int64(info.st_blocks), blockSize: 512),
            modified: modified,
            isDirectory: false
        )
    }
}
