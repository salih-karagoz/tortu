import Foundation

/// The launchd label and XPC service name of the privileged helper. It must
/// match the helper's bundle identifier exactly or `SMAppService` refuses the
/// registration.
public let tortuHelperMachServiceName = "com.muhammedsalihkaragoz.tortu.helper"

/// What the helper will say about a request.
public enum HelperOutcome: Int, Sendable, Codable {
    case completed
    case ruleNotRecognised
    case clientNotTrusted
    case blockedByRunningApplication
    case partiallyCompleted
    case failed
}

public struct HelperReport: Sendable, Codable {
    public let outcome: HelperOutcome
    public let removedPathCount: Int
    public let reclaimedBytes: Int64
    public let message: String?

    public init(
        outcome: HelperOutcome,
        removedPathCount: Int = 0,
        reclaimedBytes: Int64 = 0,
        message: String? = nil
    ) {
        self.outcome = outcome
        self.removedPathCount = removedPathCount
        self.reclaimedBytes = reclaimedBytes
        self.message = message
    }
}

/// The only surface the privileged helper exposes.
///
/// Every method takes a rule identifier. None takes a path, and none takes a
/// rule definition. The helper holds its own copy of the bundled rules, signed
/// alongside it, and resolves the identifier against that copy; a caller that
/// has been tampered with can therefore ask only for deletions the shipped
/// rules already allow. A helper that accepted a path from its client would be
/// a local privilege escalation with extra steps.
@objc public protocol TortuHelperProtocol {
    /// Rule identifiers this helper build is willing to act on.
    @objc func availableRuleIdentifiers(reply: @escaping ([String]) -> Void)

    /// Reports what `ruleIdentifier` would remove, without removing anything.
    @objc func preview(ruleIdentifier: String, reply: @escaping (Data?) -> Void)

    /// Removes what `ruleIdentifier` matches.
    @objc func perform(ruleIdentifier: String, reply: @escaping (Data?) -> Void)

    /// Version of the installed helper, so the app can prompt for an upgrade.
    @objc func version(reply: @escaping (String) -> Void)
}
