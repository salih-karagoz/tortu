import Foundation

/// The set of rules an installation knows about.
///
/// Rules that need root can only ever come from `bundled`, because the
/// privileged helper resolves identifiers against its own signed copy of that
/// same file and refuses anything it does not recognise. User-supplied rules
/// are loaded separately and are rejected if they ask for root.
public struct RuleStore: Sendable {
    public let rules: [CleanupRule]

    public init(rules: [CleanupRule]) {
        self.rules = rules
    }

    public init(data: Data, allowingRoot: Bool = true) throws {
        let file = try JSONDecoder().decode(RuleFile.self, from: data)
        if !allowingRoot, let offender = file.rules.first(where: \.requiresRoot) {
            throw RuleError.rootNotPermitted(ruleID: offender.id)
        }
        self.rules = file.rules
    }

    /// The rules that ship with the application.
    public static func bundled() throws -> RuleStore {
        guard let url = Bundle.module.url(forResource: "bundled-rules", withExtension: "json")
        else {
            throw RuleError.bundledRulesMissing
        }
        return try RuleStore(data: Data(contentsOf: url))
    }

    /// Rules written by the user, which may never ask for root.
    public static func userSupplied(data: Data) throws -> RuleStore {
        try RuleStore(data: data, allowingRoot: false)
    }

    public func rule(id: String) -> CleanupRule? {
        rules.first { $0.id == id }
    }

    public func rules(in category: RuleCategory) -> [CleanupRule] {
        rules.filter { $0.category == category }
    }

    public var categories: [RuleCategory] {
        RuleCategory.allCases.filter { category in
            rules.contains { $0.category == category }
        }
    }

    struct RuleFile: Decodable {
        let version: Int
        let rules: [CleanupRule]
    }
}
