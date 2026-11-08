#if DEBUG
import AppKit
import ScanCore
import SwiftData
import SwiftUI

/// Writes the window's own contents to a PNG, for checking a layout against
/// the design without a screen-recording grant.
///
/// Only compiled into debug builds, and only does anything when
/// `TORTU_SNAPSHOT_DIR` is set in the environment, so it cannot run during
/// ordinary use. It captures and quits; it never touches anything on disk
/// except the files it writes into that directory.
@MainActor
enum DebugSnapshot {
    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["TORTU_SNAPSHOT_DIR"],
              !path.isEmpty else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Sections to capture, or all of them when the variable is absent.
    static var sections: [SidebarSection] {
        guard let raw = ProcessInfo.processInfo.environment["TORTU_SNAPSHOT_SECTIONS"],
              !raw.isEmpty else { return SidebarSection.allCases }
        return raw.split(separator: ",").compactMap { SidebarSection(rawValue: String($0)) }
    }

    /// `pref` captures once without touching `NSApp.appearance`, which is
    /// how the user's own Appearance setting gets checked rather than
    /// overridden by the capture itself.
    static var followsPreference: Bool {
        ProcessInfo.processInfo.environment["TORTU_SNAPSHOT_THEMES"] == "pref"
    }

    static var appearances: [NSAppearance.Name?] {
        guard !followsPreference else { return [nil] }
        let raw = ProcessInfo.processInfo.environment["TORTU_SNAPSHOT_THEMES"] ?? "light"
        return raw.split(separator: ",").compactMap {
            switch $0 {
            case "light": NSAppearance.Name.aqua
            case "dark": NSAppearance.Name.darkAqua
            default: nil
            }
        }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.contentView != nil && $0.frame.width > 400 }
    }

    static func write(_ name: String) {
        guard let directory, let window = mainWindow(), let view = window.contentView,
              view.bounds.width > 1 else { return }
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try? data.write(to: directory.appending(path: "\(name).png"))
    }

    /// Whether to open the Panel's chart editor, which is a mode of a screen
    /// rather than a screen of its own.
    static var startsInChartEditor: Bool {
        ProcessInfo.processInfo.environment["TORTU_SNAPSHOT_EDITOR"] == "1"
    }

    /// Whether to also capture the menu bar panel. It lives in a window the
    /// app cannot open on its own, so it is drawn over the main window for
    /// the capture instead.
    static var capturesMenuBar: Bool {
        ProcessInfo.processInfo.environment["TORTU_SNAPSHOT_MENUBAR"] == "1"
    }

    /// Whether to measure the rules first, so the screens have real rows in
    /// them. Measuring only reads; nothing is ever removed by this path.
    static var shouldScan: Bool {
        ProcessInfo.processInfo.environment["TORTU_SNAPSHOT_SCAN"] == "1"
    }

    /// Fills a store with a plausible two months so that the screens can be
    /// checked against the design with something in them.
    ///
    /// Only ever called against the in-memory store that snapshot mode opens
    /// instead of the real one, so it cannot reach the user's own history.
    /// The shape is the one the design describes: a volume filling at
    /// roughly half a gigabyte a day, with a cliff at each cleanup, and
    /// estimates that come up a little short of what the volume returns.
    static func seed(into context: ModelContext, capacity: Int64, available: Int64) {
        let total = capacity > 0 ? capacity : 245_000_000_000
        let now = Date.now
        let day: TimeInterval = 86_400
        let mountPoint = "/"
        let cleanupDays: [Int] = [52, 38, 24, 11, 4]

        // Walk backwards from what the volume actually holds right now, so
        // the fabricated history runs into the live reading rather than
        // jumping to meet it.
        var used = Double(total - available)
        for step in 0...(60 * 4) {
            let daysAgo = Double(step) / 4
            context.insert(VolumeSample(
                timestamp: now.addingTimeInterval(-daysAgo * day),
                volumeIdentifier: mountPoint,
                totalBytes: total,
                availableBytes: Int64(max(Double(total) - used, 0))
            ))
            used -= 0.62e9 / 4
            // Going backwards, a cleanup means the volume was fuller before
            // it than after.
            if step % 4 == 0, cleanupDays.contains(Int(daysAgo)) {
                used += Double.random(in: 8e9...22e9)
            }
            used = min(max(used, Double(total) * 0.35), Double(total) * 0.97)
        }

        // One measurement a day per category.
        let categories: [(id: String, start: Double, perDay: Double)] = [
            ("xcode.derived-data", 1.2e9, 0.56e9),
            ("gradle.caches", 2.0e9, 0.33e9),
            ("flutter.build-cache", 1.4e9, 0.19e9),
            ("node.modules", 0.6e9, 0.09e9),
            ("jetbrains.caches", 2.6e9, 0.04e9),
        ]
        for category in categories {
            var size = category.start
            for daysAgo in stride(from: 60.0, through: 0, by: -1) {
                size += category.perDay
                if cleanupDays.contains(Int(daysAgo)) { size = category.start }
                context.insert(CategorySample(
                    timestamp: now.addingTimeInterval(-daysAgo * day),
                    ruleID: category.id,
                    bytes: Int64(size)
                ))
            }
        }

        // One record per cleanup, each a little short of its estimate.
        for daysAgo in cleanupDays {
            let estimated = Double.random(in: 12e9...31e9)
            let reclaimed = estimated * Double.random(in: 0.82...0.99)
            let rules = Array(categories.shuffled().prefix(Int.random(in: 2...4)))
            let summary = rules.map {
                RecordedRule(
                    id: $0.id,
                    name: $0.id,
                    estimatedBytes: Int64(estimated / Double(rules.count)),
                    pathCount: Int.random(in: 1...6)
                )
            }
            let encoded = (try? JSONEncoder().encode(summary))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            context.insert(CleanupRecord(
                timestamp: now.addingTimeInterval(-Double(daysAgo) * day),
                ruleIDs: rules.map(\.id).joined(separator: ","),
                pathCount: summary.reduce(0) { $0 + $1.pathCount },
                estimatedBytes: Int64(estimated),
                reclaimedBytes: Int64(reclaimed),
                skippedCount: Int.random(in: 0...2),
                wasDryRun: false,
                ruleSummary: encoded
            ))
        }
        try? context.save()
    }

    /// Whether to open the biggest rules out into their matched paths, and
    /// strike one of them out, so the capture shows the list as the user
    /// sees it once they have looked inside a rule.
    static var expandsRules: Bool {
        ProcessInfo.processInfo.environment["TORTU_SNAPSHOT_EXPAND"] == "1"
    }

    /// Whether to capture the screens while they are still working, which
    /// is the only way to see the waiting state at all: it is gone by the
    /// time a walk of a home folder has finished.
    static var capturesBusy: Bool {
        ProcessInfo.processInfo.environment["TORTU_SNAPSHOT_BUSY"] == "1"
    }

    /// How long to wait after the warm-up pass before capturing. A count of
    /// a whole home folder takes longer than a rule measurement does, and a
    /// capture of the waiting state must not wait at all.
    static var settleSeconds: Int {
        ProcessInfo.processInfo.environment["TORTU_SNAPSHOT_SETTLE"]
            .flatMap(Int.init) ?? (capturesBusy ? 0 : (shouldScan ? 25 : 2))
    }

    /// The capture size, `WIDTHxHEIGHT`. Taller than the design's window is
    /// useful for checking a column that scrolls.
    private static var captureSize: CGSize {
        let raw = ProcessInfo.processInfo.environment["TORTU_SNAPSHOT_SIZE"] ?? ""
        let parts = raw.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else {
            return CGSize(width: Metric.windowWidth, height: Metric.windowHeight)
        }
        return CGSize(width: parts[0], height: parts[1])
    }

    private static func resize() {
        mainWindow()?.setContentSize(captureSize)
    }

    /// Steps through every requested section in every requested appearance,
    /// then quits.
    static func run(
        select: @escaping (SidebarSection) -> Void,
        showMenuBar: @escaping (Bool) -> Void = { _ in },
        prepare: @escaping (SidebarSection) -> Void = { _ in }
    ) async {
        guard directory != nil else { return }
        resize()
        try? await Task.sleep(for: .milliseconds(400))
        // A first pass with nothing captured, so that each screen has had a
        // chance to start whatever it starts when it first appears.
        for section in sections {
            select(section)
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(settleSeconds))
        for appearance in appearances {
            if let appearance { NSApp.appearance = NSAppearance(named: appearance) }
            for section in sections {
                select(section)
                resize()
                if capturesBusy { prepare(section) }
                try? await Task.sleep(for: .milliseconds(capturesBusy ? 450 : 700))
                let suffix = appearance == .darkAqua ? "-dark" : ""
                write("\(section.rawValue)\(suffix)")
            }
            if capturesMenuBar {
                showMenuBar(true)
                try? await Task.sleep(for: .milliseconds(700))
                write("menubar\(appearance == .darkAqua ? "-dark" : "")")
                showMenuBar(false)
            }
        }
        NSApp.terminate(nil)
    }
}
#endif
