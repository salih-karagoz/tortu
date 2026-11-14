import Foundation
import HelperProtocol
import RulesEngine
import SafetyKit
import ScanCore

/// The helper's own view of what it is allowed to do.
///
/// It resolves a rule identifier against the rules compiled into *this*
/// executable, which are signed alongside it. The client never sends a path
/// and never sends a rule; if the identifier is not in this copy, the answer
/// is no. That is what keeps a tampered client from turning a root helper into
/// an arbitrary remote delete.
/// Carries an XPC reply block across an isolation boundary.
///
/// Reply blocks come from an `@objc` protocol and cannot be declared
/// `@Sendable`, but XPC guarantees each is called once, from whichever thread
/// finishes the work.
private struct ReplyBox<Value>: @unchecked Sendable {
    let send: (Value) -> Void
}

final class HelperService: NSObject, TortuHelperProtocol, @unchecked Sendable {
    private let rules: [String: CleanupRule]
    private let evaluator: RuleEvaluator
    private let remove: @Sendable (String) throws -> Void

    /// The evaluator reads the process table rather than the window server.
    /// `ProcessGuard`'s default asks `NSWorkspace`, which in a root daemon
    /// with no GUI session reports nothing running — so `blockedByProcesses`
    /// would always pass and the helper would delete the simulator's shared
    /// cache with Xcode open.
    init(
        store: RuleStore,
        evaluator: RuleEvaluator = RuleEvaluator(
            guardian: ProcessGuard(applications: SystemProcesses())
        ),
        remove: @escaping @Sendable (String) throws -> Void = { path in
            try FileManager().removeItem(at: URL(filePath: path))
        }
    ) {
        // Only root rules are reachable here. A rule that does not need root
        // has no business being run with it.
        let rootRules = store.rules.filter(\.requiresRoot)
        self.rules = Dictionary(uniqueKeysWithValues: rootRules.map { ($0.id, $0) })
        self.evaluator = evaluator
        self.remove = remove
    }

    func availableRuleIdentifiers(reply: @escaping ([String]) -> Void) {
        reply(rules.keys.sorted())
    }

    func version(reply: @escaping (String) -> Void) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        reply(version as? String ?? "0")
    }

    func preview(ruleIdentifier: String, reply: @escaping (Data?) -> Void) {
        perform(ruleIdentifier: ruleIdentifier, dryRun: true, reply: reply)
    }

    func perform(ruleIdentifier: String, reply: @escaping (Data?) -> Void) {
        perform(ruleIdentifier: ruleIdentifier, dryRun: false, reply: reply)
    }

    private func perform(
        ruleIdentifier: String,
        dryRun: Bool,
        reply: @escaping (Data?) -> Void
    ) {
        guard let rule = rules[ruleIdentifier] else {
            return reply(encode(HelperReport(outcome: .ruleNotRecognised)))
        }

        // Captured as values so the task holds no reference to the service.
        let box = ReplyBox(send: reply)
        let evaluator = evaluator
        let remove = remove

        Task {
            let evaluation = await evaluator.evaluate(rule)
            guard evaluation.blockingApplications.isEmpty else {
                return box.send(Self.encode(HelperReport(
                    outcome: .blockedByRunningApplication,
                    message: evaluation.blockingApplications.joined(separator: ", ")
                )))
            }

            var removed = 0
            var reclaimed: Int64 = 0
            var failures: [String] = []

            for candidate in evaluation.candidates {
                do {
                    // Run the same guard the unprivileged side runs, against a
                    // narrower allow list. Being root is a reason for more
                    // care, not less.
                    try PathSafety.validateForRemovalWithRootAllowances(candidate.path)
                } catch {
                    failures.append(candidate.path)
                    continue
                }
                guard !dryRun else {
                    removed += 1
                    reclaimed += candidate.size.rawValue
                    continue
                }
                do {
                    try remove(candidate.path)
                    removed += 1
                    reclaimed += candidate.size.rawValue
                } catch {
                    failures.append(candidate.path)
                }
            }

            NSLog("tortu-helper: rule=%@ dryRun=%@ removed=%d failed=%d",
                  ruleIdentifier, String(dryRun), removed, failures.count)

            box.send(Self.encode(HelperReport(
                outcome: failures.isEmpty ? .completed : .partiallyCompleted,
                removedPathCount: removed,
                reclaimedBytes: reclaimed,
                message: failures.isEmpty ? nil : failures.joined(separator: "\n")
            )))
        }
    }

    private func encode(_ report: HelperReport) -> Data? {
        Self.encode(report)
    }

    static func encode(_ report: HelperReport) -> Data? {
        try? JSONEncoder().encode(report)
    }
}
