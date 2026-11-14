import AppKit
import Darwin
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

/// Reports running applications without needing a window server session.
///
/// `NSWorkspace.runningApplications` answers for the caller's own GUI session.
/// A launchd daemon running as root has no session, so it sees an empty list,
/// every `blockedByProcesses` check passes, and the guard is silently absent
/// in the one place it matters most — the code that deletes as root. Trusting
/// the client to have checked would make the helper's whole design pointless.
///
/// This reads the process table instead, walks each executable back to the
/// bundle that contains it, and takes the identifier from that bundle's own
/// `Info.plist`. A process inside an application's helper bundle resolves to
/// the application, which errs towards blocking.
public struct SystemProcesses: RunningApplicationsProviding {
    public init() {}

    public var runningBundleIdentifiers: Set<String> {
        var identifiers: Set<String> = []
        var examined: Set<String> = []
        for pid in Self.allProcessIdentifiers() {
            guard let executable = Self.path(of: pid),
                  let bundle = Self.enclosingBundle(of: executable),
                  examined.insert(bundle).inserted,
                  let identifier = Self.identifier(ofBundleAt: bundle)
            else { continue }
            identifiers.insert(identifier)
        }
        return identifiers
    }

    /// Asks for the count first, then takes a little more room than that: the
    /// table can grow between the two calls, and a short buffer would quietly
    /// drop the processes that arrived in between.
    private static func allProcessIdentifiers() -> [pid_t] {
        let counted = proc_listallpids(nil, 0)
        guard counted > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(counted) + 64)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    private static func path(of pid: pid_t) -> String? {
        // Four kilobytes is `PROC_PIDPATHINFO_MAXSIZE`, which the header
        // declares as a macro Swift cannot see.
        var buffer = [UInt8](repeating: 0, count: 4_096)
        guard proc_pidpath(pid, &buffer, 4_096) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The innermost `.app` an executable sits inside, if any.
    private static func enclosingBundle(of executable: String) -> String? {
        var directory = (executable as NSString).deletingLastPathComponent
        while directory.count > 1 {
            if directory.hasSuffix(".app") { return directory }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func identifier(ofBundleAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any]
        else { return nil }
        return info["CFBundleIdentifier"] as? String
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
