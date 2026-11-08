import AppKit
import Foundation

/// Reports which applications are running right now.
public protocol RunningApplicationsProviding: Sendable {
    var runningBundleIdentifiers: Set<String> { get }
}

public struct WorkspaceApplications: RunningApplicationsProviding {
    public init() {}

    public var runningBundleIdentifiers: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

public struct StubApplications: RunningApplicationsProviding {
    private let identifiers: Set<String>

    public init(_ identifiers: Set<String>) {
        self.identifiers = identifiers
    }

    public var runningBundleIdentifiers: Set<String> { identifiers }
}

/// Refuses a cleanup while the application that owns the files is open.
///
/// Two separate failures made this necessary. Deleting a JetBrains IDE's cache
/// while the IDE is running corrupts its index. Deleting a running app's disk
/// image frees nothing at all, because the kernel holds the blocks until the
/// process that has the file open exits, and the user is told space was
/// reclaimed when none was.
public struct ProcessGuard: Sendable {
    private let applications: any RunningApplicationsProviding

    public init(applications: any RunningApplicationsProviding = WorkspaceApplications()) {
        self.applications = applications
    }

    /// The subset of `bundleIdentifiers` that is currently running.
    public func blockingApplications(among bundleIdentifiers: [String]) -> [String] {
        guard !bundleIdentifiers.isEmpty else { return [] }
        let running = applications.runningBundleIdentifiers
        return bundleIdentifiers.filter(running.contains).sorted()
    }

    public func isBlocked(by bundleIdentifiers: [String]) -> Bool {
        !blockingApplications(among: bundleIdentifiers).isEmpty
    }
}
