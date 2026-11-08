import Foundation
import ScanCore

public struct InstalledApplication: Sendable, Hashable, Identifiable {
    public let path: String
    public let name: String
    public let bundleIdentifier: String
    public let size: ByteCount
    /// Most recent change to anything the app keeps for itself.
    ///
    /// `kMDItemLastUsedDate` would be the obvious source and is not reliable:
    /// on a real machine it reported "never opened" for an application in
    /// daily use. The modification time of the app's own support directories
    /// is a rougher signal but an honest one, and it is presented as such.
    public let lastTrace: Date?

    public var id: String { path }
}

/// What removing an application would take with it.
public struct UninstallPlan: Sendable, Identifiable {
    public let application: InstalledApplication
    /// Files and directories that belong to this application alone.
    public let leftovers: [FoundFile]
    /// Paths that looked like leftovers but are claimed by another installed
    /// application as well, and are therefore left alone.
    public let shared: [String]

    public var id: String { application.id }

    public var totalSize: ByteCount {
        leftovers.reduce(application.size) { $0 + $1.size }
    }
}

/// Lists applications and works out what each one leaves behind.
///
/// Every location is matched on the exact bundle identifier. Nothing is
/// matched on a prefix, because `com.example` and `com.example.helper` belong
/// to different products often enough that prefix matching is how an
/// uninstaller takes a neighbour's data with it.
public struct ApplicationUninstaller: Sendable {
    /// Where an application keeps things, as a template on the bundle id.
    static let supportTemplates = [
        "Library/Application Support/%@",
        "Library/Caches/%@",
        "Library/Containers/%@",
        "Library/HTTPStorages/%@",
        "Library/WebKit/%@",
        "Library/Logs/%@",
        "Library/Preferences/%@.plist",
        "Library/Saved Application State/%@.savedState",
        "Library/Group Containers/%@",
    ]

    private let home: String
    private let scanner: DirectoryScanner

    public init(home: String = NSHomeDirectory(), scanner: DirectoryScanner = DirectoryScanner()) {
        self.home = home
        self.scanner = scanner
    }

    public func applications(in roots: [String]) async -> [InstalledApplication] {
        var found: [InstalledApplication] = []
        for root in roots {
            guard let names = try? FileManager().contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasSuffix(".app") {
                let path = root.hasSuffix("/") ? root + name : root + "/" + name
                guard let identifier = bundleIdentifier(at: path) else { continue }
                let size = (try? await scanner.scan(rootPath: path).root.totalSize) ?? .zero
                found.append(
                    InstalledApplication(
                        path: path,
                        name: String(name.dropLast(4)),
                        bundleIdentifier: identifier,
                        size: size,
                        lastTrace: lastTrace(for: identifier)
                    )
                )
            }
        }
        return found.sorted { $0.size > $1.size }
    }

    public func plan(
        for application: InstalledApplication,
        otherInstalled: [InstalledApplication]
    ) async -> UninstallPlan {
        let others = Set(otherInstalled.map(\.bundleIdentifier))
            .subtracting([application.bundleIdentifier])

        var leftovers: [FoundFile] = []
        var shared: [String] = []

        for template in Self.supportTemplates {
            let relative = String(format: template, application.bundleIdentifier)
            let path = home + "/" + relative
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }

            // If another installed application claims the same identifier,
            // this is not ours to remove.
            if others.contains(where: { path.contains("/\($0)") }) {
                shared.append(path)
                continue
            }

            let size: ByteCount = if info.st_mode & S_IFMT == S_IFDIR {
                (try? await scanner.scan(rootPath: path).root.totalSize) ?? .zero
            } else {
                ByteCount(blocks: Int64(info.st_blocks), blockSize: 512)
            }

            leftovers.append(
                FoundFile(
                    path: path, size: size,
                    modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                )
            )
        }

        return UninstallPlan(application: application, leftovers: leftovers, shared: shared)
    }

    func bundleIdentifier(at applicationPath: String) -> String? {
        let plist = applicationPath + "/Contents/Info.plist"
        guard let data = FileManager().contents(atPath: plist),
              let object = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any],
              let identifier = object["CFBundleIdentifier"] as? String,
              !identifier.isEmpty
        else { return nil }
        return identifier
    }

    func lastTrace(for bundleIdentifier: String) -> Date? {
        var latest: Date?
        for template in Self.supportTemplates {
            let path = home + "/" + String(format: template, bundleIdentifier)
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if latest == nil || date > latest! { latest = date }
        }
        return latest
    }
}
