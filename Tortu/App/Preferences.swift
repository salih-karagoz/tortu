import AppKit
import Foundation
import Observation
import RulesEngine
import ScanCore
import SwiftUI

/// Which appearance the app draws in.
///
/// The design is a token table with a light and a dark column, so following
/// the system is the honest default. The override exists because a tool that
/// lives on screen all day is sometimes wanted darker than everything else.
enum AppearanceChoice: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let defaultsKey = "appearance"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .system: "appearance.system"
        case .light: "appearance.light"
        case .dark: "appearance.dark"
        }
    }

    /// Applied to `NSApp` rather than through `preferredColorScheme`, because
    /// the menu bar panel is a window of its own that no view modifier in the
    /// main window can reach.
    @MainActor
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Which language the app draws in.
///
/// macOS has no supported way to change a running app's language, so this
/// writes the `AppleLanguages` override into the app's own defaults domain —
/// the same thing System Settings does per app — and the change takes effect
/// on the next launch. The screen says so and offers the restart rather than
/// pretending the switch was instant.
enum LanguageChoice: String, CaseIterable, Identifiable, Sendable {
    case system
    case turkish
    case english

    static let defaultsKey = "language"
    private static let overrideKey = "AppleLanguages"

    var id: String { rawValue }

    /// A language is named in its own language, never translated. "Sistem" is
    /// the exception: it is not a language.
    var title: String {
        switch self {
        case .system: String(localized: "language.system")
        case .turkish: "Türkçe"
        case .english: "English"
        }
    }

    private var code: String? {
        switch self {
        case .system: nil
        case .turkish: "tr"
        case .english: "en"
        }
    }

    func apply(to defaults: UserDefaults) {
        if let code {
            defaults.set([code], forKey: Self.overrideKey)
        } else {
            defaults.removeObject(forKey: Self.overrideKey)
        }
    }

    /// Opens a second copy and lets this one go, which is the only way the
    /// bundle re-reads its localisations.
    @MainActor
    static func restart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        ) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

/// Everything the Settings screen writes, and everything that reads it.
///
/// The switches on that screen are not decoration: each one is applied here,
/// to the rules before they are measured or to the results afterwards, so
/// that what the screen promises is what the Cleanup screen then does.
@MainActor
@Observable
final class Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        scanRoots = defaults.stringArray(forKey: Key.scanRoots) ?? [NSHomeDirectory()]
        excludedPaths = defaults.stringArray(forKey: Key.excludedPaths) ?? []
        keepNewestFlutterBuilds = defaults.bool(forKey: Key.keepFlutter, default: true)
        lockOpenApplicationCaches = defaults.bool(forKey: Key.lockOpenApps, default: true)
        leaveSimulatorRuntimes = defaults.bool(forKey: Key.leaveSimulators, default: true)
        skipRecentlyModified = defaults.bool(forKey: Key.skipRecent, default: false)
        appearance = defaults.string(forKey: AppearanceChoice.defaultsKey)
            .flatMap(AppearanceChoice.init(rawValue:)) ?? .system
        let storedLanguage = defaults.string(forKey: LanguageChoice.defaultsKey)
            .flatMap(LanguageChoice.init(rawValue:)) ?? .system
        language = storedLanguage
        // Remembered so the screen can tell a choice that is merely stored
        // from one that is actually running.
        launchLanguage = storedLanguage
        cadence = MeasurementCadence.current
        throttleOnBattery = defaults.bool(forKey: Key.throttleOnBattery, default: true)
        freeSpaceThresholdGB = defaults.double(forKey: Key.freeThreshold, default: 20)
        daysToFullThreshold = defaults.double(forKey: Key.daysThreshold, default: 14)
        growthThresholdGBPerDay = defaults.double(forKey: Key.growthThreshold, default: 1)
    }

    private enum Key {
        static let scanRoots = "scanRoots"
        static let excludedPaths = "excludedPaths"
        static let keepFlutter = "protect.flutterKeepNewest"
        static let lockOpenApps = "protect.lockOpenApplicationCaches"
        static let leaveSimulators = "protect.leaveSimulatorRuntimes"
        static let skipRecent = "protect.skipRecentlyModified"
        static let throttleOnBattery = "throttleOnBattery"
        static let freeThreshold = "notify.freeSpaceGB"
        static let daysThreshold = "notify.daysToFull"
        static let growthThreshold = "notify.growthGBPerDay"
    }

    /// How recent counts as recent, for the switch that leaves fresh files
    /// alone. A week is the span over which a build directory is still
    /// likely to be the one being worked in.
    static let recentWindow: TimeInterval = 7 * 86_400

    var scanRoots: [String] { didSet { defaults.set(scanRoots, forKey: Key.scanRoots) } }
    var excludedPaths: [String] { didSet { defaults.set(excludedPaths, forKey: Key.excludedPaths) } }

    var keepNewestFlutterBuilds: Bool { didSet { defaults.set(keepNewestFlutterBuilds, forKey: Key.keepFlutter) } }
    var lockOpenApplicationCaches: Bool { didSet { defaults.set(lockOpenApplicationCaches, forKey: Key.lockOpenApps) } }
    var leaveSimulatorRuntimes: Bool { didSet { defaults.set(leaveSimulatorRuntimes, forKey: Key.leaveSimulators) } }
    var skipRecentlyModified: Bool { didSet { defaults.set(skipRecentlyModified, forKey: Key.skipRecent) } }

    var appearance: AppearanceChoice {
        didSet {
            defaults.set(appearance.rawValue, forKey: AppearanceChoice.defaultsKey)
            appearance.apply()
        }
    }

    var language: LanguageChoice {
        didSet {
            defaults.set(language.rawValue, forKey: LanguageChoice.defaultsKey)
            language.apply(to: defaults)
        }
    }

    /// The language the running copy was launched with.
    let launchLanguage: LanguageChoice

    var needsRestartForLanguage: Bool { language != launchLanguage }

    var cadence: MeasurementCadence {
        didSet { defaults.set(cadence.rawValue, forKey: MeasurementCadence.defaultsKey) }
    }
    var throttleOnBattery: Bool { didSet { defaults.set(throttleOnBattery, forKey: Key.throttleOnBattery) } }

    var freeSpaceThresholdGB: Double { didSet { defaults.set(freeSpaceThresholdGB, forKey: Key.freeThreshold) } }
    var daysToFullThreshold: Double { didSet { defaults.set(daysToFullThreshold, forKey: Key.daysThreshold) } }
    var growthThresholdGBPerDay: Double { didSet { defaults.set(growthThresholdGBPerDay, forKey: Key.growthThreshold) } }

    // MARK: Applying the settings

    /// Rules as they should be measured, after the protections are applied.
    ///
    /// The simulator switch removes a rule outright rather than leaving it
    /// visible and unchecked, because a rule listed with a size next to it is
    /// an invitation to tick it.
    func rules(from catalogue: [CleanupRule]) -> [CleanupRule] {
        catalogue.compactMap { rule in
            if rule.id == "coresimulator.dyld-cache", leaveSimulatorRuntimes {
                return nil
            }
            // Turning the Flutter protection off means every build directory
            // goes, including the one the current project builds from.
            if rule.id == "flutter.build-cache", !keepNewestFlutterBuilds {
                return CleanupRule(
                    id: rule.id,
                    name: rule.name,
                    category: rule.category,
                    paths: rule.paths,
                    strategy: .deleteAll,
                    blockedByProcesses: rule.blockedByProcesses,
                    requiresRoot: rule.requiresRoot,
                    regrows: rule.regrows,
                    cost: rule.cost
                )
            }
            return rule
        }
    }

    /// Results as they should be shown, after the exclusions are applied.
    func filter(_ evaluations: [RuleEvaluation], now: Date = .now) -> [RuleEvaluation] {
        let cutoff = now.addingTimeInterval(-Self.recentWindow)
        return evaluations.map { evaluation in
            var candidates = evaluation.candidates
            var kept = evaluation.kept

            if !excludedPaths.isEmpty {
                let excluded = candidates.filter { isExcluded($0.path) }
                candidates.removeAll { isExcluded($0.path) }
                kept.append(contentsOf: excluded)
            }
            if skipRecentlyModified {
                let recent = candidates.filter { $0.modified > cutoff }
                candidates.removeAll { $0.modified > cutoff }
                kept.append(contentsOf: recent)
            }

            return RuleEvaluation(
                rule: evaluation.rule,
                candidates: candidates,
                kept: kept,
                blockingApplications: lockOpenApplicationCaches
                    ? evaluation.blockingApplications : []
            )
        }
    }

    /// A path is excluded when it is one of the excluded paths or sits inside
    /// one. Compared as path components, so `/Users/x/Pro` does not exclude
    /// `/Users/x/Projects`.
    func isExcluded(_ path: String) -> Bool {
        excludedPaths.contains { prefix in
            path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
        }
    }
}

private extension UserDefaults {
    /// `bool(forKey:)` cannot tell "false" from "never set", which matters
    /// for every setting here that defaults to on.
    func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) == nil ? fallback : bool(forKey: key)
    }

    func double(forKey key: String, default fallback: Double) -> Double {
        object(forKey: key) == nil ? fallback : double(forKey: key)
    }
}
