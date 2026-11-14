import CleanerKit
import FindersKit
import Foundation
import Observation
import ScanCore

@MainActor
@Observable
final class FindersController {
    enum Mode: String, CaseIterable, Identifiable {
        case largeFiles, duplicates, applications
        var id: String { rawValue }
    }

    /// What a search can say about itself while it is still running.
    ///
    /// The two file searches walk a tree with no total to count towards, so
    /// they report what they have seen; the application survey knows how many
    /// applications there are before it starts, so it reports a fraction.
    /// Neither invents the other's figure.
    struct Progress: Equatable, Sendable {
        var entriesSeen = 0
        var bytesAccounted = ByteCount.zero
        var currentPath = ""
        var fraction: Double?
    }

    enum Phase {
        case idle
        case working(Progress?)
        case largeFiles([FoundFile])
        case duplicates([DuplicateGroup])
        case applications([UninstallPlan])
        case failed(String)
    }

    var mode: Mode = .largeFiles
    private(set) var phase: Phase = .idle
    private(set) var selectedPaths: Set<String> = []
    /// Which copy of each duplicate group to keep, by group identifier.
    ///
    /// Here rather than in the view for the same reason the search itself
    /// is: the view is thrown away and rebuilt every time the sidebar moves,
    /// and a choice the user made about which copy to keep should not go
    /// with it.
    private(set) var kept: [String: String] = [:]
    private(set) var lastTrashed: Int?

    var root: String = NSHomeDirectory()
    /// When the search under way started.
    private(set) var startedAt: Date?
    /// Whether a search has been asked for at all yet, so that the screen
    /// starts the first one by itself and never restarts one the user
    /// stopped.
    private(set) var hasRun = false
    var minimumSizeMB: Double = 100
    var untouchedForDays: Double = 0

    private var task: Task<Void, Never>?
    private let remover: any FileRemoving = SystemFileRemover()

    /// Whether the root was set from outside and must not be replaced by the
    /// setting when the screen appears.
    private(set) var hasChosenRoot = false

    init() {
        #if DEBUG
        if let root = DebugSnapshot.root {
            self.root = root
            hasChosenRoot = true
        }
        #endif
    }

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    var selectedSize: ByteCount {
        switch phase {
        case let .duplicates(groups):
            groups.flatMap(\.files)
                .filter { selectedPaths.contains($0.path) }
                .reduce(ByteCount.zero) { $0 + $1.size }
        case let .applications(plans):
            plans.filter { selectedPaths.contains($0.application.path) }
                .reduce(ByteCount.zero) { $0 + $1.totalSize }
        default: .zero
        }
    }

    func isSelected(_ path: String) -> Bool { selectedPaths.contains(path) }

    /// Replaces the selection wholesale.
    ///
    /// Duplicates are chosen by saying which copy to keep, not which ones to
    /// remove, so the screen computes the whole set and hands it over rather
    /// than toggling its way there one path at a time.
    func setSelection(_ paths: Set<String>) {
        selectedPaths = paths
    }

    /// Records which copy of a duplicate group to keep.
    func keep(_ path: String, in group: String) {
        kept[group] = path
    }

    func toggle(_ path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
    }

    func run() {
        task?.cancel()
        selectedPaths = []
        kept = [:]
        lastTrashed = nil
        phase = .working(nil)
        startedAt = .now
        hasRun = true
        let root = root
        let criteria = FindCriteria(
            minimumSize: ByteCount(Int64(minimumSizeMB * 1_000_000)),
            untouchedFor: untouchedForDays > 0 ? untouchedForDays * 86_400 : nil
        )
        let mode = mode

        // The walk reports from whichever thread is reading, so each report
        // hops back to the main actor before it touches state.
        let report: @Sendable (ScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.isWorking else { return }
                self.phase = .working(
                    Progress(
                        entriesSeen: progress.entriesSeen,
                        bytesAccounted: progress.bytesAccounted,
                        currentPath: progress.currentPath
                    )
                )
            }
        }

        task = Task {
            do {
                switch mode {
                case .largeFiles:
                    let files = try await LargeFileFinder()
                        .find(under: root, criteria: criteria, onProgress: report)
                    guard !Task.isCancelled else { return }
                    phase = .largeFiles(files)

                case .duplicates:
                    let finder = DuplicateFinder(
                        options: .init(minimumSize: criteria.minimumSize)
                    )
                    let groups = try await finder.find(under: root, onProgress: report)
                    guard !Task.isCancelled else { return }
                    phase = .duplicates(groups)

                case .applications:
                    let uninstaller = ApplicationUninstaller()
                    let apps = await uninstaller.applications(in: [
                        "/Applications", NSHomeDirectory() + "/Applications",
                    ])
                    var plans: [UninstallPlan] = []
                    for app in apps {
                        plans.append(await uninstaller.plan(for: app, otherInstalled: apps))
                        guard !Task.isCancelled else { return }
                        phase = .working(
                            Progress(
                                entriesSeen: plans.count,
                                bytesAccounted: plans.reduce(ByteCount.zero) { $0 + $1.totalSize },
                                currentPath: app.name,
                                fraction: Double(plans.count) / Double(max(apps.count, 1))
                            )
                        )
                    }
                    guard !Task.isCancelled else { return }
                    phase = .applications(plans.sorted { $0.totalSize > $1.totalSize })
                }
            } catch {
                phase = .failed(String(describing: error))
            }
        }
    }

    /// Stops a search and leaves the screen where it was before it started.
    ///
    /// A walk of a home folder can run for minutes, and nothing it does is
    /// worth finishing against the user's wishes: it only reads.
    func cancel() {
        task?.cancel()
        task = nil
        startedAt = nil
        phase = .idle
    }

    /// Everything here goes to the Trash, never straight out.
    ///
    /// These are the two surfaces that remove things a person made rather than
    /// things a tool generated. A mistake has to be recoverable, and the only
    /// recovery macOS offers is the Trash.
    func trashSelected() {
        let paths = pathsToTrash()
        guard !paths.isEmpty else { return }
        var trashed = 0
        for path in paths {
            if (try? remover.trash(at: path)) != nil { trashed += 1 }
        }
        lastTrashed = trashed
        selectedPaths = []
        run()
    }

    private func pathsToTrash() -> [String] {
        switch phase {
        case let .duplicates(groups):
            groups.flatMap(\.files).map(\.path).filter(selectedPaths.contains)
        case let .applications(plans):
            plans
                .filter { selectedPaths.contains($0.application.path) }
                .flatMap { [$0.application.path] + $0.leftovers.map(\.path) }
        default: []
        }
    }
}
