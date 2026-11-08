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
        try await service.unregister()
    }

    /// Rule identifiers this helper build is willing to act on. Useful on its
    /// own: a mismatch means the app and the helper are different versions.
    public func availableRuleIdentifiers() async throws -> [String] {
        let proxy = try proxy()
        return await withCheckedContinuation { continuation in
            proxy.availableRuleIdentifiers { continuation.resume(returning: $0) }
        }
    }

    public func perform(ruleIdentifier: String, dryRun: Bool) async throws -> HelperReport {
        let proxy = try proxy()
        let data: Data? = await withCheckedContinuation { continuation in
            if dryRun {
                proxy.preview(ruleIdentifier: ruleIdentifier) { continuation.resume(returning: $0) }
            } else {
                proxy.perform(ruleIdentifier: ruleIdentifier) { continuation.resume(returning: $0) }
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

    private func proxy() throws -> any TortuHelperProtocol {
        guard status == .enabled else { throw HelperError.notEnabled(status) }

        let connection = existingOrNewConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in })
            as? any TortuHelperProtocol
        else {
            throw HelperError.connectionFailed("the helper exported an unexpected interface")
        }
        return proxy
    }

    private func existingOrNewConnection() -> NSXPCConnection {
        if let connection { return connection }
        let created = NSXPCConnection(
            machServiceName: tortuHelperMachServiceName, options: .privileged
        )
        created.remoteObjectInterface = NSXPCInterface(with: TortuHelperProtocol.self)
        created.invalidationHandler = { [weak self] in
            Task { await self?.forgetConnection() }
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
