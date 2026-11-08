import AppKit
import Foundation
import Observation
import ScanCore

@MainActor
@Observable
final class ScanController {
    enum Phase {
        case idle
        case scanning(ScanProgress?)
        case finished(ScanResult)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// When the last count finished, so the screen can say how old its
    /// figures are.
    private(set) var lastFinished: Date?
    /// When the count under way started. A walk of a home folder has no
    /// total to count towards, so the elapsed time is the only honest
    /// measure of progress the screen can offer.
    private(set) var startedAt: Date?
    var rootPath: String = NSHomeDirectory()
    /// Whether a count has been asked for at all yet.
    ///
    /// The screen starts the first one by itself. It must not start the
    /// second: now that the controller outlives the view, a count the user
    /// stopped would otherwise begin again the next time they looked at the
    /// screen.
    private(set) var hasRun = false
    /// Whether the user picked the folder themselves, in which case the
    /// setting must not quietly replace it on the next visit.
    private(set) var hasChosenRoot = false

    // MARK: Where the user is in the result
    //
    // These are not scanning state, but they belong to the count rather than
    // to the view: SwiftUI throws a screen's own state away the moment the
    // sidebar moves off it, and a tree that collapses itself every time the
    // user glances at another screen is no better than one that recounts
    // itself. Both outlast the view here.

    /// Directories the user has opened.
    var expanded: Set<String> = []
    /// The directory the breadcrumb and the tree are showing, if the user
    /// has descended into one.
    var selected: String?
    /// Sort by name rather than by size.
    var sortByName = false
    /// Show only what a rule already covers.
    var sedimentOnly = false

    private var task: Task<Void, Never>?

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var result: ScanResult? {
        if case let .finished(result) = phase { return result }
        return nil
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: rootPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootPath = url.path(percentEncoded: false)
        hasChosenRoot = true
        phase = .idle
    }

    func start() {
        task?.cancel()
        phase = .scanning(nil)
        startedAt = .now
        hasRun = true
        // A new count is a new tree, so where the user was in the old one
        // means nothing. How they asked to see it — sorted by name, rules
        // only — is a preference and survives.
        expanded = []
        selected = nil
        let path = rootPath

        task = Task {
            let scanner = DirectoryScanner()
            // Progress arrives from whichever thread is walking, so each
            // report hops back to the main actor before touching state.
            let report: @Sendable (ScanProgress) -> Void = { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.isScanning else { return }
                    self.phase = .scanning(progress)
                }
            }
            do {
                let result = try await scanner.scan(rootPath: path, onProgress: report)
                guard !Task.isCancelled else { return }
                lastFinished = .now
                phase = .finished(result)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(String(describing: error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        startedAt = nil
        phase = .idle
    }
}
