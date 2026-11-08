import CleanerKit
import Foundation
import Observation
import RulesEngine
import ScanCore

@MainActor
@Observable
final class CleanupController {
    /// How far the measurement has got.
    ///
    /// The rules are measured concurrently and land in whatever order they
    /// finish, so `rule` is the one that just came back rather than the one
    /// being worked on. `found` is the total of everything measured so far,
    /// which is why the figure on screen climbs instead of appearing at the
    /// end.
    struct Analysis: Equatable, Sendable {
        var measured = 0
        var total = 0
        var found = ByteCount.zero
        var rule: String?

        var fraction: Double? {
            total > 0 ? Double(measured) / Double(total) : nil
        }
    }

    /// How far a run has got, counted in paths because that is what the
    /// runner reports. The bytes are not counted out live: what a removal
    /// actually returns is only known once the volume is measured again, and
    /// the screen says so afterwards rather than guessing during.
    struct Run: Equatable, Sendable {
        var done = 0
        var total = 0
        var path: String?

        var fraction: Double? {
            total > 0 ? Double(min(done, total)) / Double(total) : nil
        }
    }

    enum Phase {
        case idle
        case analysing(Analysis)
        case ready(CleanupPlan)
        case running(Run)
        case finished(CleanupResult, CleanupPlan)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var selection: Set<String> = []

    // MARK: The paths behind a rule
    //
    // A rule is a pattern, and a pattern matches whatever is there — for
    // `~/**/node_modules` that is every project on the machine. Removing all
    // of them because one line in a catalogue said so is exactly the kind of
    // thing this application exists not to do, so a rule opens out into the
    // paths it matched and any one of them can be struck out on its own.

    /// Rules whose matched paths are open on screen.
    var expandedRules: Set<String> = []

    /// Paths struck out of an otherwise selected rule.
    ///
    /// Only ever holds paths of rules that are selected, and never all the
    /// paths of one: striking out the last leaves the rule with nothing to
    /// do, so the rule itself comes off instead.
    private(set) var excludedPaths: Set<String> = []

    /// The rule catalogue, loaded once at launch so that the sidebar can
    /// print how many rules exist before anything has been scanned.
    private(set) var rules: [CleanupRule] = []
    private(set) var catalogError: String?
    private(set) var lastAnalysis: Date?
    /// When the work under way started.
    private(set) var startedAt: Date?

    /// The user's settings, applied to the catalogue before it is measured
    /// and to the results afterwards. Set once at launch.
    var preferences: Preferences?

    var ruleCount: Int { rules.count }

    /// Called when an analysis finishes, so the sizes can be recorded as a
    /// point in each rule's series. Growth is only visible because these are
    /// kept.
    var onAnalysed: (@MainActor ([RuleEvaluation]) -> Void)?
    /// Called when a run finishes, with what was asked for and what happened.
    var onFinished: (@MainActor (CleanupResult, CleanupPlan, Set<String>) -> Void)?

    private var task: Task<Void, Never>?

    var plan: CleanupPlan? {
        switch phase {
        case let .ready(plan): plan
        case let .finished(_, plan): plan
        default: nil
        }
    }

    var lastResult: CleanupResult? {
        if case let .finished(result, _) = phase { return result }
        return nil
    }

    var isBusy: Bool {
        switch phase {
        case .analysing, .running: true
        default: false
        }
    }

    var selectedReclaim: ByteCount {
        guard let plan else { return .zero }
        return plan.actionable
            .filter { selection.contains($0.id) }
            .reduce(ByteCount.zero) { $0 + remaining(of: $1).bytes }
    }

    /// What a rule would still remove once the struck-out paths are taken
    /// off it. The figure in the rule's own column stays what was found;
    /// this is what the footer promises.
    func remaining(of evaluation: RuleEvaluation) -> (count: Int, bytes: ByteCount) {
        guard !excludedPaths.isEmpty else {
            return (evaluation.candidates.count, evaluation.reclaimable)
        }
        let kept = evaluation.candidates.filter { !excludedPaths.contains($0.path) }
        return (kept.count, kept.reduce(ByteCount.zero) { $0 + $1.size })
    }

    func isExpanded(_ id: String) -> Bool { expandedRules.contains(id) }

    func toggleExpansion(_ id: String) {
        if expandedRules.contains(id) {
            expandedRules.remove(id)
        } else {
            expandedRules.insert(id)
        }
    }

    /// Whether this path will be removed if the run happens now.
    func isPathSelected(_ path: String, in evaluation: RuleEvaluation) -> Bool {
        selection.contains(evaluation.id) && !excludedPaths.contains(path)
    }

    func togglePath(_ path: String, in evaluation: RuleEvaluation) {
        guard selection.contains(evaluation.id) else { return }
        if excludedPaths.contains(path) {
            excludedPaths.remove(path)
            return
        }
        let left = evaluation.candidates.filter {
            $0.path != path && !excludedPaths.contains($0.path)
        }
        if left.isEmpty {
            // Nothing would be left to remove, which is the same thing as
            // not running the rule. Said that way, the row reads straight.
            selection.remove(evaluation.id)
            clearExclusions(of: evaluation)
        } else {
            excludedPaths.insert(path)
        }
    }

    private func clearExclusions(of evaluation: RuleEvaluation) {
        for candidate in evaluation.candidates { excludedPaths.remove(candidate.path) }
    }

    /// The plan as it would run: every rule the user kept, holding only the
    /// paths they did not strike out.
    private func trimmed(_ plan: CleanupPlan) -> CleanupPlan {
        guard !excludedPaths.isEmpty else { return plan }
        return CleanupPlan(evaluations: plan.evaluations.map { evaluation in
            RuleEvaluation(
                rule: evaluation.rule,
                candidates: evaluation.candidates.filter { !excludedPaths.contains($0.path) },
                kept: evaluation.kept
                    + evaluation.candidates.filter { excludedPaths.contains($0.path) },
                blockingApplications: evaluation.blockingApplications
            )
        })
    }

    var selectedCount: Int {
        guard let plan else { return 0 }
        return plan.actionable.filter { selection.contains($0.id) }.count
    }

    func loadCatalog() {
        guard rules.isEmpty else { return }
        do {
            rules = try RuleStore.bundled().rules
            catalogError = nil
        } catch {
            catalogError = String(describing: error)
        }
    }

    func isSelected(_ id: String) -> Bool { selection.contains(id) }

    /// Turning a rule off and on again means the whole rule, so whatever was
    /// struck out of it goes back.
    func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        if let evaluation = plan?.evaluations.first(where: { $0.id == id }) {
            clearExclusions(of: evaluation)
        }
    }

    func setAll(_ selected: Bool) {
        guard let plan else { return }
        selection = selected ? Set(plan.actionable.map(\.id)) : []
        excludedPaths = []
    }

    func analyse() {
        task?.cancel()
        startedAt = .now
        loadCatalog()
        let catalogue = preferences?.rules(from: rules) ?? rules
        phase = .analysing(Analysis(total: catalogue.count))
        // Each rule reports from the task that measured it, so the tally is
        // kept here on the main actor rather than across them.
        let report: @Sendable (RuleEvaluation) -> Void = { [weak self] evaluation in
            Task { @MainActor in
                guard let self, case let .analysing(state) = self.phase else { return }
                self.phase = .analysing(
                    Analysis(
                        measured: state.measured + 1,
                        total: state.total,
                        found: state.found + evaluation.reclaimable,
                        rule: evaluation.rule.name.resolved()
                    )
                )
            }
        }

        task = Task {
            let measured = await RuleEvaluator().evaluate(catalogue, onProgress: report)
            guard !Task.isCancelled else { return }
            let evaluations = preferences?.filter(measured) ?? measured
            let plan = CleanupPlan(evaluations: evaluations)
            // Everything runnable starts selected; the user unticks what
            // they want to keep rather than hunting for what to include.
            selection = Set(plan.actionable.map(\.id))
            excludedPaths = []
            lastAnalysis = .now
            onAnalysed?(evaluations)
            phase = .ready(plan)
        }
    }

    func run(mode: CleanupRunner.Mode) {
        guard let measured = plan else { return }
        task?.cancel()
        startedAt = .now
        let chosen = selection
        // What runs is the trimmed plan, so a struck-out path is not merely
        // hidden from the screen: it is not in what the runner is handed,
        // and it is not in what the history records either.
        let plan = trimmed(measured)
        excludedPaths = []
        let total = plan.evaluations
            .filter { chosen.contains($0.id) }
            .reduce(0) { $0 + $1.candidates.count }
        phase = .running(Run(total: total))

        let report: @Sendable (String) -> Void = { [weak self] path in
            Task { @MainActor in
                guard let self, case let .running(state) = self.phase else { return }
                self.phase = .running(
                    Run(done: state.done + 1, total: state.total, path: path)
                )
            }
        }

        task = Task {
            let runner = CleanupRunner()
            let result = await runner.run(plan, ruleIDs: chosen, mode: mode, onProgress: report)
            guard !Task.isCancelled else { return }
            onFinished?(result, plan, chosen)
            phase = .finished(result, plan)
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        startedAt = nil
        selection = []
        excludedPaths = []
        phase = .idle
    }
}
