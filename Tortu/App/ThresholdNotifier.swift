import Foundation
import HistoryKit
import ScanCore
import SwiftData
import UserNotifications

/// Tells the user when a threshold they set has been crossed.
///
/// The three thresholds in Settings existed before this did: they were stored
/// and nothing read them, while the screen said otherwise. An instrument whose
/// whole claim is that it measures honestly cannot have a settings page that
/// promises something it does not do, so either the promise or the behaviour
/// had to go. The behaviour is the useful half.
///
/// Three rules keep it from becoming noise:
///
/// - Nothing is sent without permission, and permission is asked for in
///   Settings, next to the thresholds, rather than sprung at launch.
/// - One notification per condition per day. A disk that sits below the
///   threshold for a week is one fact, not seven.
/// - A condition that clears forgets it fired, so crossing back over says so
///   again.
@MainActor
struct ThresholdNotifier {
    private let context: ModelContext
    private let preferences: Preferences
    private let defaults: UserDefaults

    init(context: ModelContext, preferences: Preferences, defaults: UserDefaults = AppDefaults.store) {
        self.context = context
        self.preferences = preferences
        self.defaults = defaults
    }

    /// Which thresholds have something to say.
    enum Condition: String, CaseIterable {
        case freeSpace
        case daysToFull
        case growth

        var key: String { "notify.last.\(rawValue)" }
    }

    // MARK: Permission

    /// The completion-handler form rather than the async one: awaiting
    /// `notificationSettings()` hands back the whole settings object across
    /// an isolation boundary, and it is not `Sendable`. Only the one value
    /// that matters crosses here.
    static func authorisation() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    /// Asks once. A refusal is final until the user changes it in System
    /// Settings, and the screen says so rather than asking again.
    @discardableResult
    static func requestAuthorisation() async -> UNAuthorizationStatus {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        return await authorisation()
    }

    // MARK: Checking

    /// Looks at the current reading and the series behind it, and sends at
    /// most one notification for each condition.
    ///
    /// `names` maps a rule identifier to the name the user would recognise,
    /// so a notification can say "Xcode DerivedData" rather than
    /// "xcode.derived-data".
    func check(_ stats: VolumeStats, names: [String: String] = [:], now: Date = .now) async {
        guard await Self.authorisation() == .authorized else { return }

        let freeGB = Double(stats.available.rawValue) / 1_000_000_000
        if preferences.freeSpaceThresholdGB > 0, freeGB < preferences.freeSpaceThresholdGB {
            send(
                .freeSpace,
                title: String(localized: "notify.free.title"),
                body: String(
                    localized: "notify.free.body \(Figure.bytes(stats.available).joined) \(Figure.count(Int(preferences.freeSpaceThresholdGB)))"
                ),
                now: now
            )
        } else {
            clear(.freeSpace)
        }

        let recorder = HistoryRecorder(context: context)

        if preferences.daysToFullThreshold > 0,
           let days = daysToFull(recorder: recorder, free: stats.available, now: now),
           Double(days) <= preferences.daysToFullThreshold {
            send(
                .daysToFull,
                title: String(localized: "notify.days.title"),
                body: String(localized: "notify.days.body \(days)"),
                now: now
            )
        } else {
            clear(.daysToFull)
        }

        if preferences.growthThresholdGBPerDay > 0,
           let fastest = fastestGrowth(recorder: recorder),
           fastest.rate.bytesPerDay / 1_000_000_000 >= preferences.growthThresholdGBPerDay {
            let name = names[fastest.series.id] ?? fastest.series.id
            send(
                .growth,
                title: String(localized: "notify.growth.title"),
                body: String(
                    localized: "notify.growth.body \(name) \(Figure.gigabytesPerDay(fastest.rate.bytesPerDay))"
                ),
                now: now
            )
        } else {
            clear(.growth)
        }
    }

    /// Days until free space reaches zero at the rate the series shows, or
    /// nil when free space is not falling — in which case there is no date to
    /// project and the app says nothing rather than inventing one.
    private func daysToFull(
        recorder: HistoryRecorder, free: ByteCount, now: Date
    ) -> Int? {
        let series = recorder.freeSpaceSeries()
        guard series.samples.count >= GrowthAnalysis.minimumSamples,
              let rate = GrowthAnalysis.rate(of: series),
              let exhaustion = GrowthAnalysis.projectedExhaustion(
                  free: free, rate: rate, from: now
              ) else { return nil }
        return max(Int((exhaustion.timeIntervalSince(now) / 86_400).rounded()), 0)
    }

    private func fastestGrowth(
        recorder: HistoryRecorder
    ) -> (series: Series, rate: GrowthRate)? {
        GrowthAnalysis.rankedByGrowth(recorder.categorySeries()).first
    }

    // MARK: Sending

    private func send(_ condition: Condition, title: String, body: String, now: Date) {
        if let last = defaults.object(forKey: condition.key) as? Date,
           now.timeIntervalSince(last) < 86_400 {
            return
        }
        defaults.set(now, forKey: condition.key)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Delivered at once rather than on a trigger: the condition is true
        // now, and a scheduled copy of it could arrive after it stopped being.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "tortu.\(condition.rawValue)", content: content, trigger: nil
            )
        )
    }

    private func clear(_ condition: Condition) {
        defaults.removeObject(forKey: condition.key)
    }
}
