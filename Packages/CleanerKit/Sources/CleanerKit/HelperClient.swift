import Foundation
import HelperProtocol
import ServiceManagement

/// Talks to the privileged helper, and reports honestly when it cannot.
public actor HelperClient {
    public enum Status: Sendable, Equatable {
        /// Never registered.
        case notRegistered
        /// Registered, waiting for the user to allow it in System Settings.
        case awaitingApproval
        case enabled
        /// Registered by a build that is no longer installed.
        case requiresReinstall
        case unknown
    }

    public enum HelperError: Error, Sendable, Equatable {
        case notEnabled(Status)
        case connectionFailed(String)
        case malformedReply
        case refused(HelperOutcome, message: String?)
    }

    public static let plistName = "com.muhammedsalihkaragoz.tortu.helper.plist"

    private let service: SMAppService
    private var connection: NSXPCConnection?

    public init() {
        self.service = SMAppService.daemon(plistName: Self.plistName)
    }

    public var status: Status {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .awaitingApproval
        case .notFound: .requiresReinstall
        @unknown default: .unknown
        }
    }

    /// Registers the daemon. macOS then asks the user to allow it; nothing
    /// runs as root until they do.
    public func register() throws {
        try service.register()
    }

    public func unregister() async throws {
        closeConnection()
        // The completion-handler form rather than the async one. `SMAppService`
        // is not `Sendable`, and awaiting its async method means handing the
        // service itself across a suspension point, which Swift 6 refuses.
        // Here the call happens synchronously in the actor's own context and
        // only the continuation crosses.
        let service = service
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            service.unregister { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Rule identifiers this helper build is willing to act on. Useful on its
    /// own: a mismatch means the app and the helper are different versions.
    public func availableRuleIdentifiers() async throws -> [String] {
        try await call { proxy, finish in
            proxy.availableRuleIdentifiers { finish($0) }
        }
    }

    public func perform(ruleIdentifier: String, dryRun: Bool) async throws -> HelperReport {
        let data: Data? = try await call { proxy, finish in
            if dryRun {
                proxy.preview(ruleIdentifier: ruleIdentifier) { finish($0) }
            } else {
                proxy.perform(ruleIdentifier: ruleIdentifier) { finish($0) }
            }
        }
        guard let data, let report = try? JSONDecoder().decode(HelperReport.self, from: data) else {
            throw HelperError.malformedReply
        }
        guard report.outcome == .completed || report.outcome == .partiallyCompleted else {
            throw HelperError.refused(report.outcome, message: report.message)
        }
        return report
    }

    /// One round trip to the helper.
    ///
    /// XPC answers a message in one of two ways: the reply block, or the error
    /// handler, when the connection breaks before a reply can arrive. The
    /// earlier shape resumed the continuation only from the reply block and
    /// discarded the error, so a helper that crashed, was unregistered, or
    /// became unreachable left the caller awaiting a reply that would never
    /// come. `CleanupRunner` awaits this, so the cleanup would have sat on
    /// "running" for the rest of the session with no way back.
    ///
    /// Both paths finish the continuation now, and `SingleResume` makes it
    /// exactly once, because resuming twice is a crash rather than a warning.
    private func call<Value: Sendable>(
        _ send: (any TortuHelperProtocol, @escaping (Value) -> Void) -> Void
    ) async throws -> Value {
        guard status == .enabled else { throw HelperError.notEnabled(status) }

        let connection = existingOrNewConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = SingleResume(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                once.fail(HelperError.connectionFailed(error.localizedDescription))
            }) as? any TortuHelperProtocol else {
                once.fail(
                    HelperError.connectionFailed("the helper exported an unexpected interface")
                )
                return
            }
            send(proxy) { once.succeed($0) }
        }
    }

    private func existingOrNewConnection() -> NSXPCConnection {
        if let connection { return connection }
        let created = NSXPCConnection(
            machServiceName: tortuHelperMachServiceName, options: .privileged
        )
        created.remoteObjectInterface = NSXPCInterface(with: TortuHelperProtocol.self)
        // Interruption is the helper crashing or being replaced. The
        // connection object survives it, but the one held here is dropped so
        // the next call builds a fresh one rather than reusing a connection
        // whose peer has changed underneath it.
        created.interruptionHandler = { [weak self] in
            guard let self else { return }
            Task { await self.forgetConnection() }
        }
        created.invalidationHandler = { [weak self] in
            // Unwrapped before the task rather than chained through `self?`:
            // the optional chain forms an optional async call, which Swift 6
            // cannot prove is safe to send into a task from an XPC queue.
            guard let self else { return }
            Task { await self.forgetConnection() }
        }
        created.resume()
        connection = created
        return created
    }

    private func forgetConnection() {
        connection = nil
    }

    private func closeConnection() {
        connection?.invalidate()
        connection = nil
    }
}

/// Resumes a continuation exactly once.
///
/// XPC promises to call either a reply block or an error handler, never both,
/// but nothing in the type system holds it to that, and the two arrive on
/// different queues. Resuming a `CheckedContinuation` twice traps, so the
/// promise is enforced here rather than relied upon.
private final class SingleResume<Value: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, any Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Value) {
        take()?.resume(returning: value)
    }

    func fail(_ error: any Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }
}
