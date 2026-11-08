import Foundation

public enum RuleCategory: String, Sendable, Codable, CaseIterable {
    case developer
    case browser
    case system
    case mail
    case media
    case other
}

/// One cleanable thing Tortu knows about.
///
/// Rules are data, not code. Keeping them in files means a contributor can add
/// a cleaner without writing Swift, and it means the privileged helper can
/// carry its own signed copy and refuse anything that is not in it.
public struct CleanupRule: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: LocalizedText
    public let category: RuleCategory
    /// Glob patterns, `~` relative to the user's home.
    public let paths: [String]
    public let strategy: CleanupStrategy
    /// Bundle identifiers that must not be running for this rule to apply.
    public let blockedByProcesses: [String]
    /// Whether removal needs the privileged helper. A rule that sets this can
    /// only ever come from the signed, bundled set.
    public let requiresRoot: Bool
    /// Whether the files come back on their own during normal work.
    public let regrows: Bool
    /// What the user gives up by running this rule.
    public let cost: LocalizedText

    public init(
        id: String,
        name: LocalizedText,
        category: RuleCategory,
        paths: [String],
        strategy: CleanupStrategy,
        blockedByProcesses: [String] = [],
        requiresRoot: Bool = false,
        regrows: Bool = true,
        cost: LocalizedText
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.paths = paths
        self.strategy = strategy
        self.blockedByProcesses = blockedByProcesses
        self.requiresRoot = requiresRoot
        self.regrows = regrows
        self.cost = cost
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(LocalizedText.self, forKey: .name)
        self.category = try container.decode(RuleCategory.self, forKey: .category)
        self.paths = try container.decode([String].self, forKey: .paths)
        self.strategy = try container.decode(CleanupStrategy.self, forKey: .strategy)
        self.blockedByProcesses = try container.decodeIfPresent(
            [String].self, forKey: .blockedByProcesses
        ) ?? []
        self.requiresRoot = try container.decodeIfPresent(Bool.self, forKey: .requiresRoot) ?? false
        self.regrows = try container.decodeIfPresent(Bool.self, forKey: .regrows) ?? true
        self.cost = try container.decode(LocalizedText.self, forKey: .cost)
        try validate()
    }

    /// Rejects patterns that could reach outside the directory a rule names.
    ///
    /// The helper re-runs this on its own copy before acting, so a malformed or
    /// hostile rule cannot turn a root deletion into an arbitrary one.
    public func validate() throws {
        guard !id.isEmpty else { throw RuleError.emptyIdentifier }
        guard !paths.isEmpty else { throw RuleError.noPaths(ruleID: id) }
        for path in paths {
            guard !path.contains("..") else {
                throw RuleError.unsafePath(ruleID: id, path: path, reason: "contains '..'")
            }
            guard path.hasPrefix("~/") || path.hasPrefix("/") else {
                throw RuleError.unsafePath(ruleID: id, path: path, reason: "is not absolute")
            }
            guard path != "/" && path != "~/" else {
                throw RuleError.unsafePath(ruleID: id, path: path, reason: "names a whole volume")
            }
        }
    }
}

public enum RuleError: Error, Sendable, Equatable {
    case emptyIdentifier
    case noPaths(ruleID: String)
    case unsafePath(ruleID: String, path: String, reason: String)
    case rootNotPermitted(ruleID: String)
    case bundledRulesMissing
}
