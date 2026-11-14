import Foundation
import Testing
@testable import FindersKit
import ScanCore

@Suite("Application uninstaller")
struct UninstallerTests {
    /// Builds a fake home with two applications and the support directories
    /// each would leave behind.
    static func makeWorld() throws -> (home: URL, applications: URL) {
        let manager = FileManager.default
        let base = URL.temporaryDirectory.appending(path: "tortu-apps-\(UUID().uuidString)")
        let home = base.appending(path: "home")
        let applications = base.appending(path: "Applications")
        try manager.createDirectory(at: applications, withIntermediateDirectories: true)

        for (name, identifier) in [("Widget", "com.example.widget"),
                                   ("Widget Helper", "com.example.widget.helper")] {
            let bundle = applications.appending(path: "\(name).app/Contents")
            try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": identifier]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: bundle.appending(path: "Info.plist"))
            try Data(repeating: 0x41, count: 50_000)
                .write(to: bundle.appending(path: "payload.bin"))
        }

        for identifier in ["com.example.widget", "com.example.widget.helper"] {
            let support = home.appending(path: "Library/Application Support/\(identifier)")
            try manager.createDirectory(at: support, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: 30_000)
                .write(to: support.appending(path: "state.bin"))
        }
        let preferences = home.appending(path: "Library/Preferences")
        try manager.createDirectory(at: preferences, withIntermediateDirectories: true)
        try Data(repeating: 0x43, count: 1_000)
            .write(to: preferences.appending(path: "com.example.widget.plist"))

        return (home, applications)
    }

    @Test("Lists applications with their bundle identifiers and sizes")
    func listsApplications() async throws {
        let world = try Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.home.deletingLastPathComponent()) }

        let uninstaller = ApplicationUninstaller(home: world.home.path(percentEncoded: false))
        let apps = await uninstaller.applications(
            in: [world.applications.path(percentEncoded: false)]
        )
        #expect(apps.count == 2)
        #expect(Set(apps.map(\.bundleIdentifier)) ==
                ["com.example.widget", "com.example.widget.helper"])
        #expect(apps.allSatisfy { $0.size > .zero })
    }

    /// The failure this design exists to prevent: removing `com.example.widget`
    /// must not take `com.example.widget.helper` with it, even though one
    /// identifier is a prefix of the other.
    @Test("A neighbouring application's data is left alone")
    func doesNotTakeNeighbourData() async throws {
        let world = try Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.home.deletingLastPathComponent()) }

        let uninstaller = ApplicationUninstaller(home: world.home.path(percentEncoded: false))
        let apps = await uninstaller.applications(
            in: [world.applications.path(percentEncoded: false)]
        )
        let widget = try #require(apps.first { $0.bundleIdentifier == "com.example.widget" })

        let plan = await uninstaller.plan(for: widget, otherInstalled: apps)
        let paths = plan.leftovers.map(\.path)

        #expect(paths.contains { $0.hasSuffix("Application Support/com.example.widget") })
        #expect(paths.contains { $0.hasSuffix("com.example.widget.plist") })
        #expect(
            !paths.contains { $0.contains("com.example.widget.helper") },
            "the helper's own data must not be in the widget's plan"
        )
    }

    /// The other direction, which used to fail. `com.example.widget` is
    /// installed and `com.example.widget.helper` is being removed: the
    /// helper's own paths contain the neighbour's identifier as a prefix, and
    /// a substring test marked every one of them shared, so uninstalling the
    /// helper removed nothing and said so.
    @Test("A neighbour whose identifier is a prefix does not block a removal")
    func prefixNeighbourDoesNotBlock() async throws {
        let world = try Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.home.deletingLastPathComponent()) }

        let uninstaller = ApplicationUninstaller(home: world.home.path(percentEncoded: false))
        let apps = await uninstaller.applications(
            in: [world.applications.path(percentEncoded: false)]
        )
        let helper = try #require(
            apps.first { $0.bundleIdentifier == "com.example.widget.helper" }
        )

        let plan = await uninstaller.plan(for: helper, otherInstalled: apps)

        #expect(plan.shared.isEmpty)
        #expect(plan.leftovers.contains {
            $0.path.hasSuffix("Application Support/com.example.widget.helper")
        })
    }

    /// Two copies of one application, which is what the shared list is for.
    @Test("A second copy with the same identifier holds the support paths back")
    func secondCopyIsShared() async throws {
        let world = try Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.home.deletingLastPathComponent()) }

        let uninstaller = ApplicationUninstaller(home: world.home.path(percentEncoded: false))
        let apps = await uninstaller.applications(
            in: [world.applications.path(percentEncoded: false)]
        )
        let widget = try #require(apps.first { $0.bundleIdentifier == "com.example.widget" })
        let duplicate = InstalledApplication(
            path: "/Users/someone/Applications/Widget.app", name: "Widget",
            bundleIdentifier: "com.example.widget", size: ByteCount(1), lastTrace: nil
        )

        let plan = await uninstaller.plan(for: widget, otherInstalled: apps + [duplicate])

        #expect(plan.leftovers.isEmpty)
        #expect(!plan.shared.isEmpty)
    }

    @Test("Nothing is listed for an application that left nothing behind")
    func noLeftovers() async throws {
        let world = try Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.home.deletingLastPathComponent()) }

        let uninstaller = ApplicationUninstaller(home: world.home.path(percentEncoded: false))
        let stranger = InstalledApplication(
            path: "/nowhere/Stranger.app", name: "Stranger",
            bundleIdentifier: "com.nobody.stranger", size: ByteCount(1), lastTrace: nil
        )
        let plan = await uninstaller.plan(for: stranger, otherInstalled: [])
        #expect(plan.leftovers.isEmpty)
        #expect(plan.totalSize == ByteCount(1))
    }

    @Test("A bundle without an identifier is skipped rather than guessed at")
    func skipsBundlesWithoutIdentifier() async throws {
        let manager = FileManager.default
        let base = URL.temporaryDirectory.appending(path: "tortu-noid-\(UUID().uuidString)")
        let bundle = base.appending(path: "Broken.app/Contents")
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }

        let uninstaller = ApplicationUninstaller(home: NSHomeDirectory())
        #expect(uninstaller.bundleIdentifier(at: bundle.deletingLastPathComponent()
            .path(percentEncoded: false)) == nil)
        #expect(await uninstaller.applications(in: [base.path(percentEncoded: false)]).isEmpty)
    }

    @Test("The total covers the application and everything it left")
    func totalIncludesLeftovers() async throws {
        let world = try Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.home.deletingLastPathComponent()) }

        let uninstaller = ApplicationUninstaller(home: world.home.path(percentEncoded: false))
        let apps = await uninstaller.applications(
            in: [world.applications.path(percentEncoded: false)]
        )
        let widget = try #require(apps.first { $0.bundleIdentifier == "com.example.widget" })
        let plan = await uninstaller.plan(for: widget, otherInstalled: apps)
        #expect(plan.totalSize > widget.size)
    }
}
