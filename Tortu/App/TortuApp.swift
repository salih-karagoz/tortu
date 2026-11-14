import Entitlements
import ScanCore
import SwiftData
import SwiftUI

@main
struct TortuApp: App {
    @State private var monitor = VolumeMonitor()
    @State private var cleanup = CleanupController()
    @State private var preferences = Preferences()
    /// Which section the window is showing. It lives here rather than inside
    /// the window so that the Settings menu item can move the window to the
    /// Settings section; the design puts Settings in the sidebar, not in a
    /// separate preferences window.
    @State private var selection: SidebarSection = .panel

    /// A licence is verified offline against a key compiled into the app. If
    /// there is no licence, or it fails to verify, the app runs as the free
    /// build rather than refusing to start.
    private let entitlements: any EntitlementProviding = {
        #if DEBUG
        // Snapshot mode never reads the real licence: a capture of a paid
        // screen must not depend on which licence this machine happens to
        // hold, and a capture of the locked state would be impossible on a
        // machine that holds one.
        if DebugSnapshot.directory != nil {
            return DebugSnapshot.showsFree ? FreeEntitlements() : FixedEntitlements.everything
        }
        #endif
        guard let verifier = try? LicenseVerifier(
            publicKeyRepresentation: TortuKeys.licensePublicKey
        ) else {
            return FreeEntitlements()
        }
        return EntitlementLoader(verifier: verifier).load(from: TortuKeys.licenseURL).provider
    }()

    private let container: ModelContainer = {
        #if DEBUG
        // Snapshot mode never opens the real store. Checking a screen's
        // layout must not be able to write into, or read, the user's own
        // measurements.
        if DebugSnapshot.directory != nil {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try! ModelContainer(
                for: VolumeSample.self, CategorySample.self, CleanupRecord.self,
                configurations: configuration
            )
            let stats = try? VolumeStats.forHomeVolume()
            DebugSnapshot.seed(
                into: ModelContext(container),
                capacity: stats?.total.rawValue ?? 0,
                available: stats?.available.rawValue ?? 0
            )
            return container
        }
        #endif
        do {
            return try ModelContainer(for: VolumeSample.self, CategorySample.self, CleanupRecord.self)
        } catch {
            // A broken store must not take the app down; measurement still
            // works without history, so fall back to memory and carry on.
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(
                for: VolumeSample.self, CategorySample.self, CleanupRecord.self,
                configurations: configuration
            )
        }
    }()

    init() {
        // Core Text has to know about the bundled faces before the first view
        // is laid out, or the first frame renders in the system font.
        Face.register()
    }

    var body: some Scene {
        Window("app.name", id: "main") {
            MainWindow(selection: $selection)
                .defaultAppStorage(AppDefaults.store)
                .environment(monitor)
                .environment(cleanup)
                .environment(preferences)
                .environment(\.entitlements, entitlements)
                .task {
                    preferences.appearance.apply()
                    cleanup.preferences = preferences
                    cleanup.loadCatalog()
                    await monitor.start()
                }
        }
        .defaultSize(width: Metric.windowWidth, height: Metric.windowHeight)
        // The sidebar runs to the top of the window and the traffic lights
        // sit on top of it, as the design draws them. There is no title bar
        // to show a title in.
        .windowStyle(.hiddenTitleBar)
        .modelContainer(container)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsCommand(selection: $selection)
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(monitor)
                .environment(cleanup)
                .environment(preferences)
                .modelContainer(container)
        } label: {
            MenuBarLabel()
                .environment(monitor)
        }
        // A window, not a menu: the sparkline cannot live in a menu item.
        .menuBarExtraStyle(.window)
    }
}

/// Keeps ⌘, working now that Settings is a section of the main window rather
/// than a separate scene.
private struct SettingsCommand: View {
    @Binding var selection: SidebarSection
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            selection = .settings
            openWindow(id: "main")
        } label: {
            Text("menu.settings")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

private struct EntitlementsKey: EnvironmentKey {
    static let defaultValue: any EntitlementProviding = FreeEntitlements()
}

extension EnvironmentValues {
    var entitlements: any EntitlementProviding {
        get { self[EntitlementsKey.self] }
        set { self[EntitlementsKey.self] = newValue }
    }
}
